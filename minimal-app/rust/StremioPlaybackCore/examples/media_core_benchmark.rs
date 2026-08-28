use std::{
    error::Error,
    fmt::Write as _,
    fs,
    hint::black_box,
    io,
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

use stremio_playback_core::media::{
    ContainerSummary, MatroskaSession, MediaError, MediaTrack, ReadAt,
};

const MIB: f64 = 1024.0 * 1024.0;

#[derive(Debug)]
struct Config {
    fixture: PathBuf,
    fixture_label: String,
    fixture_provenance: String,
    fixture_sha256: Option<String>,
    json_output: PathBuf,
    warmups: usize,
    repetitions: usize,
    seek_operations: usize,
    ffprobe: Option<PathBuf>,
    external_warmups: usize,
    external_repetitions: usize,
}

#[derive(Clone)]
struct ArcSource {
    bytes: Arc<[u8]>,
}

impl ReadAt for ArcSource {
    fn len(&self) -> u64 {
        self.bytes.len() as u64
    }

    fn read_at(&mut self, offset: u64, output: &mut [u8]) -> Result<usize, MediaError> {
        let offset = usize::try_from(offset).map_err(|_| MediaError::ArithmeticOverflow)?;
        if offset >= self.bytes.len() {
            return Ok(0);
        }
        let count = output.len().min(self.bytes.len() - offset);
        output[..count].copy_from_slice(&self.bytes[offset..offset + count]);
        Ok(count)
    }
}

#[derive(Debug)]
struct IntegerStats {
    samples: Vec<u64>,
    min: u64,
    median: f64,
    mean: f64,
    p95: u64,
    max: u64,
}

#[derive(Debug)]
struct FloatStats {
    samples: Vec<f64>,
    min: f64,
    median: f64,
    mean: f64,
    p95: f64,
    max: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DemuxObservation {
    packet_count: u64,
    payload_bytes: u64,
    checksum: u64,
}

#[derive(Debug)]
struct DemuxBenchmark {
    elapsed: IntegerStats,
    payload_throughput_mib_s: FloatStats,
    observation: DemuxObservation,
}

#[derive(Debug)]
struct SeekBenchmark {
    per_operation_ns: IntegerStats,
    checksum: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ExternalObservation {
    stdout_bytes: usize,
    checksum: u64,
}

#[derive(Debug)]
struct ExternalBenchmark {
    metadata_process: IntegerStats,
    packet_scan_process: IntegerStats,
    metadata_observation: ExternalObservation,
    packet_scan_observation: ExternalObservation,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("benchmark failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let config = parse_arguments()?;
    let fixture_path = config.fixture.canonicalize()?;
    let bytes: Arc<[u8]> = fs::read(&fixture_path)?.into();
    if bytes.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "fixture is empty").into());
    }

    let baseline = open_session(&bytes)?;
    let summary = baseline.summary();
    let tracks = baseline.tracks().to_vec();
    let fixture_fingerprint = fnv1a64(&bytes);
    black_box(metadata_fingerprint(&baseline));

    let open_samples = benchmark_open(&bytes, config.warmups, config.repetitions)?;
    let demux = benchmark_demux(&bytes, config.warmups, config.repetitions)?;
    let seek_targets = deterministic_seek_targets(summary.duration_ns, config.seek_operations);
    let seek = benchmark_seek(&bytes, &seek_targets, config.warmups, config.repetitions)?;
    let external = config
        .ffprobe
        .as_deref()
        .map(|ffprobe| {
            benchmark_ffprobe(
                ffprobe,
                &fixture_path,
                config.external_warmups,
                config.external_repetitions,
            )
        })
        .transpose()?;

    let open_stats = integer_stats(open_samples);
    let run_epoch_ms = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis();
    let json = render_json(
        &config,
        &fixture_path,
        bytes.len(),
        fixture_fingerprint,
        &summary,
        &tracks,
        &open_stats,
        &demux,
        &seek,
        external.as_ref(),
        run_epoch_ms,
    );
    fs::write(&config.json_output, json)?;
    print_summary(
        &config,
        &fixture_path,
        bytes.len(),
        &summary,
        &open_stats,
        &demux,
        &seek,
        external.as_ref(),
    );
    Ok(())
}

fn parse_arguments() -> Result<Config, Box<dyn Error>> {
    let mut fixture = None;
    let mut fixture_label = "custom".to_owned();
    let mut fixture_provenance = "caller-provided fixture".to_owned();
    let mut fixture_sha256 = None;
    let mut json_output = None;
    let mut warmups = 5;
    let mut repetitions = 25;
    let mut seek_operations = 500;
    let mut ffprobe = None;
    let mut external_warmups = 1;
    let mut external_repetitions = 5;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--fixture" => fixture = Some(PathBuf::from(next_value(&mut arguments, "--fixture")?)),
            "--fixture-label" => fixture_label = next_value(&mut arguments, "--fixture-label")?,
            "--fixture-provenance" => {
                fixture_provenance = next_value(&mut arguments, "--fixture-provenance")?
            }
            "--fixture-sha256" => {
                fixture_sha256 = Some(next_value(&mut arguments, "--fixture-sha256")?)
            }
            "--json-output" => {
                json_output = Some(PathBuf::from(next_value(&mut arguments, "--json-output")?))
            }
            "--warmups" => warmups = parse_count(&mut arguments, "--warmups", 0, 1_000)?,
            "--repetitions" => {
                repetitions = parse_count(&mut arguments, "--repetitions", 1, 1_000)?
            }
            "--seek-operations" => {
                seek_operations = parse_count(&mut arguments, "--seek-operations", 1, 1_000_000)?
            }
            "--ffprobe" => ffprobe = Some(PathBuf::from(next_value(&mut arguments, "--ffprobe")?)),
            "--external-warmups" => {
                external_warmups = parse_count(&mut arguments, "--external-warmups", 0, 100)?
            }
            "--external-repetitions" => {
                external_repetitions =
                    parse_count(&mut arguments, "--external-repetitions", 1, 100)?
            }
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            unknown => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument: {unknown}"),
                )
                .into());
            }
        }
    }
    Ok(Config {
        fixture: fixture.ok_or_else(|| missing("--fixture"))?,
        fixture_label,
        fixture_provenance,
        fixture_sha256,
        json_output: json_output.ok_or_else(|| missing("--json-output"))?,
        warmups,
        repetitions,
        seek_operations,
        ffprobe,
        external_warmups,
        external_repetitions,
    })
}

fn next_value(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, io::Error> {
    arguments.next().ok_or_else(|| missing(option))
}

fn parse_count(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
    minimum: usize,
    maximum: usize,
) -> Result<usize, io::Error> {
    let value = next_value(arguments, option)?;
    let parsed = value.parse::<usize>().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{option} must be an integer"),
        )
    })?;
    if !(minimum..=maximum).contains(&parsed) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{option} must be between {minimum} and {maximum}"),
        ));
    }
    Ok(parsed)
}

fn missing(option: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("missing value for {option}"),
    )
}

fn print_help() {
    println!(
        "Usage: media_core_benchmark --fixture PATH --json-output PATH [options]\n\
         Options:\n\
           --fixture-label TEXT\n\
           --fixture-provenance TEXT\n\
           --fixture-sha256 HEX\n\
           --warmups N                 default: 5\n\
           --repetitions N             default: 25\n\
           --seek-operations N         default: 500 per repetition\n\
           --ffprobe PATH              optional external-process reference\n\
           --external-warmups N        default: 1\n\
           --external-repetitions N    default: 5"
    );
}

fn open_session(bytes: &Arc<[u8]>) -> Result<MatroskaSession, MediaError> {
    MatroskaSession::open(Box::new(ArcSource {
        bytes: Arc::clone(bytes),
    }))
}

fn benchmark_open(
    bytes: &Arc<[u8]>,
    warmups: usize,
    repetitions: usize,
) -> Result<Vec<u64>, MediaError> {
    let mut expected = None;
    let mut samples = Vec::with_capacity(repetitions);
    for iteration in 0..warmups + repetitions {
        let started = Instant::now();
        let session = open_session(bytes)?;
        let elapsed = elapsed_ns(started);
        let fingerprint = metadata_fingerprint(&session);
        if let Some(expected) = expected {
            if expected != fingerprint {
                return Err(MediaError::InvalidData(
                    "metadata changed between repetitions",
                ));
            }
        } else {
            expected = Some(fingerprint);
        }
        black_box(fingerprint);
        if iteration >= warmups {
            samples.push(elapsed);
        }
    }
    Ok(samples)
}

fn metadata_fingerprint(session: &MatroskaSession) -> u64 {
    let summary = session.summary();
    let mut fingerprint = 0xcbf29ce484222325_u64;
    mix(&mut fingerprint, summary.duration_ns);
    mix(&mut fingerprint, u64::from(summary.track_count));
    mix(&mut fingerprint, u64::from(summary.cue_count));
    mix(&mut fingerprint, u64::from(summary.cluster_count));
    for track in session.tracks() {
        mix(&mut fingerprint, track.number);
        mix(&mut fingerprint, u64::from(track.codec as u32));
        mix(&mut fingerprint, u64::from(track.kind as u32));
    }
    fingerprint
}

fn benchmark_demux(
    bytes: &Arc<[u8]>,
    warmups: usize,
    repetitions: usize,
) -> Result<DemuxBenchmark, MediaError> {
    let mut expected = None;
    let mut elapsed_samples = Vec::with_capacity(repetitions);
    let mut throughput_samples = Vec::with_capacity(repetitions);
    for iteration in 0..warmups + repetitions {
        let mut session = open_session(bytes)?;
        select_every_track(&mut session)?;
        let started = Instant::now();
        let observation = demux_all_packets(&mut session)?;
        let elapsed = elapsed_ns(started);
        if let Some(expected) = expected {
            if expected != observation {
                return Err(MediaError::InvalidData(
                    "demux output changed between repetitions",
                ));
            }
        } else {
            expected = Some(observation);
        }
        black_box(observation.checksum);
        if iteration >= warmups {
            elapsed_samples.push(elapsed);
            throughput_samples.push(mib_per_second(observation.payload_bytes, elapsed));
        }
    }
    Ok(DemuxBenchmark {
        elapsed: integer_stats(elapsed_samples),
        payload_throughput_mib_s: float_stats(throughput_samples),
        observation: expected.expect("at least one timed or warmup iteration"),
    })
}

fn select_every_track(session: &mut MatroskaSession) -> Result<(), MediaError> {
    for index in 0..session.tracks().len() {
        session.set_track_selected(index, true)?;
    }
    Ok(())
}

fn demux_all_packets(session: &mut MatroskaSession) -> Result<DemuxObservation, MediaError> {
    let mut packet_count = 0_u64;
    let mut payload_bytes = 0_u64;
    let mut checksum = 0xcbf29ce484222325_u64;
    while let Some(packet) = session.next_packet()? {
        packet_count = packet_count.saturating_add(1);
        payload_bytes = payload_bytes.saturating_add(packet.payload.len() as u64);
        mix(&mut checksum, u64::from(packet.track_index));
        mix(&mut checksum, packet.timestamp_ns as u64);
        mix(&mut checksum, packet.duration_ns);
        mix(&mut checksum, packet.payload.len() as u64);
        if let Some(first) = packet.payload.first() {
            mix(&mut checksum, u64::from(*first));
        }
        if let Some(last) = packet.payload.last() {
            mix(&mut checksum, u64::from(*last));
        }
        black_box(packet.payload.as_ptr());
    }
    Ok(DemuxObservation {
        packet_count,
        payload_bytes,
        checksum,
    })
}

fn benchmark_seek(
    bytes: &Arc<[u8]>,
    targets: &[u64],
    warmups: usize,
    repetitions: usize,
) -> Result<SeekBenchmark, MediaError> {
    let mut expected = None;
    let mut samples = Vec::with_capacity(repetitions);
    for iteration in 0..warmups + repetitions {
        let mut session = open_session(bytes)?;
        select_every_track(&mut session)?;
        let started = Instant::now();
        let mut checksum = 0xcbf29ce484222325_u64;
        for &target in targets {
            session.seek(target)?;
            let packet = session
                .next_packet()?
                .ok_or(MediaError::InvalidData("seek produced no packet"))?;
            mix(&mut checksum, target);
            mix(&mut checksum, packet.timestamp_ns as u64);
            mix(&mut checksum, u64::from(packet.track_index));
            mix(&mut checksum, packet.payload.len() as u64);
            black_box(packet.payload.as_ptr());
        }
        let elapsed = elapsed_ns(started);
        if let Some(expected) = expected {
            if expected != checksum {
                return Err(MediaError::InvalidData(
                    "seek output changed between repetitions",
                ));
            }
        } else {
            expected = Some(checksum);
        }
        black_box(checksum);
        if iteration >= warmups {
            samples.push((elapsed / targets.len() as u64).max(1));
        }
    }
    Ok(SeekBenchmark {
        per_operation_ns: integer_stats(samples),
        checksum: expected.expect("at least one timed or warmup iteration"),
    })
}

fn deterministic_seek_targets(duration_ns: u64, count: usize) -> Vec<u64> {
    let upper_bound = duration_ns.saturating_sub(1).max(1);
    let mut state = 0x6a09e667f3bcc909_u64;
    (0..count)
        .map(|index| {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407_u64 ^ index as u64);
            ((u128::from(state) * u128::from(upper_bound)) / u128::from(u64::MAX)) as u64
        })
        .collect()
}

fn benchmark_ffprobe(
    ffprobe: &Path,
    fixture: &Path,
    warmups: usize,
    repetitions: usize,
) -> Result<ExternalBenchmark, Box<dyn Error>> {
    let (metadata_samples, metadata_observation) =
        benchmark_external_command(warmups, repetitions, || {
            run_ffprobe(ffprobe, fixture, false)
        })?;
    let (packet_samples, packet_observation) =
        benchmark_external_command(warmups, repetitions, || run_ffprobe(ffprobe, fixture, true))?;
    Ok(ExternalBenchmark {
        metadata_process: integer_stats(metadata_samples),
        packet_scan_process: integer_stats(packet_samples),
        metadata_observation,
        packet_scan_observation: packet_observation,
    })
}

fn benchmark_external_command(
    warmups: usize,
    repetitions: usize,
    mut command: impl FnMut() -> Result<(u64, ExternalObservation), Box<dyn Error>>,
) -> Result<(Vec<u64>, ExternalObservation), Box<dyn Error>> {
    let mut expected = None;
    let mut samples = Vec::with_capacity(repetitions);
    for iteration in 0..warmups + repetitions {
        let (elapsed, observation) = command()?;
        if let Some(expected) = expected {
            if expected != observation {
                return Err(io::Error::other("ffprobe output changed between repetitions").into());
            }
        } else {
            expected = Some(observation);
        }
        if iteration >= warmups {
            samples.push(elapsed);
        }
    }
    Ok((samples, expected.expect("at least one external iteration")))
}

fn run_ffprobe(
    ffprobe: &Path,
    fixture: &Path,
    count_packets: bool,
) -> Result<(u64, ExternalObservation), Box<dyn Error>> {
    let mut command = Command::new(ffprobe);
    command.args(["-v", "error"]);
    if count_packets {
        command.args([
            "-count_packets",
            "-show_entries",
            "stream=index,nb_read_packets",
            "-of",
            "json",
        ]);
    } else {
        command.args([
            "-show_entries",
            "format=duration,size:stream=index,codec_name,codec_type",
            "-of",
            "json",
        ]);
    }
    command.arg(fixture);
    let started = Instant::now();
    let output = command.output()?;
    let elapsed = elapsed_ns(started);
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "ffprobe exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ))
        .into());
    }
    let observation = ExternalObservation {
        stdout_bytes: output.stdout.len(),
        checksum: fnv1a64(&output.stdout),
    };
    black_box(observation.checksum);
    Ok((elapsed, observation))
}

fn integer_stats(samples: Vec<u64>) -> IntegerStats {
    assert!(!samples.is_empty());
    let mut sorted = samples.clone();
    sorted.sort_unstable();
    let sum = samples.iter().map(|value| *value as f64).sum::<f64>();
    IntegerStats {
        min: sorted[0],
        median: median_u64(&sorted),
        mean: sum / samples.len() as f64,
        p95: sorted[percentile_index(sorted.len(), 0.95)],
        max: *sorted.last().expect("nonempty samples"),
        samples,
    }
}

fn float_stats(samples: Vec<f64>) -> FloatStats {
    assert!(!samples.is_empty());
    let mut sorted = samples.clone();
    sorted.sort_by(f64::total_cmp);
    let sum = samples.iter().sum::<f64>();
    FloatStats {
        min: sorted[0],
        median: median_f64(&sorted),
        mean: sum / samples.len() as f64,
        p95: sorted[percentile_index(sorted.len(), 0.95)],
        max: *sorted.last().expect("nonempty samples"),
        samples,
    }
}

fn percentile_index(length: usize, percentile: f64) -> usize {
    ((length as f64 * percentile).ceil() as usize)
        .saturating_sub(1)
        .min(length - 1)
}

fn median_u64(sorted: &[u64]) -> f64 {
    let middle = sorted.len() / 2;
    if sorted.len().is_multiple_of(2) {
        (sorted[middle - 1] as f64 + sorted[middle] as f64) / 2.0
    } else {
        sorted[middle] as f64
    }
}

fn median_f64(sorted: &[f64]) -> f64 {
    let middle = sorted.len() / 2;
    if sorted.len().is_multiple_of(2) {
        (sorted[middle - 1] + sorted[middle]) / 2.0
    } else {
        sorted[middle]
    }
}

fn elapsed_ns(started: Instant) -> u64 {
    started.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64
}

fn mib_per_second(bytes: u64, elapsed_ns: u64) -> f64 {
    (bytes as f64 / MIB) / (elapsed_ns.max(1) as f64 / 1_000_000_000.0)
}

fn mix(checksum: &mut u64, value: u64) {
    *checksum ^= value;
    *checksum = checksum.wrapping_mul(0x100000001b3);
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut checksum = 0xcbf29ce484222325_u64;
    for &byte in bytes {
        checksum ^= u64::from(byte);
        checksum = checksum.wrapping_mul(0x100000001b3);
    }
    checksum
}

#[allow(clippy::too_many_arguments)]
fn render_json(
    config: &Config,
    fixture_path: &Path,
    fixture_bytes: usize,
    fixture_fingerprint: u64,
    summary: &ContainerSummary,
    tracks: &[MediaTrack],
    open: &IntegerStats,
    demux: &DemuxBenchmark,
    seek: &SeekBenchmark,
    external: Option<&ExternalBenchmark>,
    run_epoch_ms: u128,
) -> String {
    let mut json = String::new();
    writeln!(json, "{{").unwrap();
    writeln!(json, "  \"schema_version\": 1,").unwrap();
    writeln!(json, "  \"benchmark\": \"stremio_rust_matroska_core\",").unwrap();
    writeln!(json, "  \"run_epoch_ms\": {run_epoch_ms},").unwrap();
    writeln!(
        json,
        "  \"build\": {{\"profile\": \"{}\", \"os\": \"{}\", \"arch\": \"{}\", \"crate_version\": \"{}\"}},",
        if cfg!(debug_assertions) { "debug" } else { "release" },
        json_escape(std::env::consts::OS),
        json_escape(std::env::consts::ARCH),
        env!("CARGO_PKG_VERSION")
    )
    .unwrap();
    writeln!(json, "  \"fixture\": {{").unwrap();
    writeln!(
        json,
        "    \"path\": \"{}\",",
        json_escape(&fixture_path.display().to_string())
    )
    .unwrap();
    writeln!(
        json,
        "    \"label\": \"{}\",",
        json_escape(&config.fixture_label)
    )
    .unwrap();
    writeln!(
        json,
        "    \"provenance\": \"{}\",",
        json_escape(&config.fixture_provenance)
    )
    .unwrap();
    match &config.fixture_sha256 {
        Some(value) => writeln!(json, "    \"sha256\": \"{}\",", json_escape(value)).unwrap(),
        None => writeln!(json, "    \"sha256\": null,").unwrap(),
    }
    writeln!(json, "    \"fnv1a64\": \"{fixture_fingerprint:016x}\",").unwrap();
    writeln!(json, "    \"file_bytes\": {fixture_bytes},").unwrap();
    writeln!(
        json,
        "    \"document_type\": \"{}\",",
        json_escape(&summary.document_type)
    )
    .unwrap();
    writeln!(json, "    \"duration_ns\": {},", summary.duration_ns).unwrap();
    writeln!(json, "    \"track_count\": {},", summary.track_count).unwrap();
    writeln!(json, "    \"cue_count\": {},", summary.cue_count).unwrap();
    writeln!(json, "    \"cluster_count\": {},", summary.cluster_count).unwrap();
    writeln!(json, "    \"tracks\": [").unwrap();
    for (index, track) in tracks.iter().enumerate() {
        writeln!(
            json,
            "      {{\"index\": {}, \"number\": {}, \"kind\": \"{:?}\", \"codec\": \"{:?}\", \"codec_id\": \"{}\", \"language\": \"{}\"}}{}",
            track.index,
            track.number,
            track.kind,
            track.codec,
            json_escape(&track.codec_id),
            json_escape(&track.language),
            if index + 1 == tracks.len() { "" } else { "," }
        )
        .unwrap();
    }
    writeln!(json, "    ]").unwrap();
    writeln!(json, "  }},").unwrap();
    writeln!(
        json,
        "  \"config\": {{\"warmups\": {}, \"repetitions\": {}, \"seek_operations_per_repetition\": {}, \"external_warmups\": {}, \"external_repetitions\": {}}},",
        config.warmups,
        config.repetitions,
        config.seek_operations,
        config.external_warmups,
        config.external_repetitions
    )
    .unwrap();
    writeln!(json, "  \"metrics\": {{").unwrap();
    writeln!(
        json,
        "    \"open_and_index_metadata_ns\": {},",
        integer_stats_json(open)
    )
    .unwrap();
    writeln!(json, "    \"full_packet_demux\": {{").unwrap();
    writeln!(json, "      \"scope\": \"next_packet loop after session open; all tracks selected; includes packet allocation, payload copies, and lightweight accounting\",").unwrap();
    writeln!(
        json,
        "      \"packet_count\": {},",
        demux.observation.packet_count
    )
    .unwrap();
    writeln!(
        json,
        "      \"payload_bytes\": {},",
        demux.observation.payload_bytes
    )
    .unwrap();
    writeln!(
        json,
        "      \"checksum\": \"{:016x}\",",
        demux.observation.checksum
    )
    .unwrap();
    writeln!(
        json,
        "      \"elapsed_ns\": {},",
        integer_stats_json(&demux.elapsed)
    )
    .unwrap();
    writeln!(
        json,
        "      \"payload_mib_per_second\": {}",
        float_stats_json(&demux.payload_throughput_mib_s)
    )
    .unwrap();
    writeln!(json, "    }},").unwrap();
    writeln!(
        json,
        "    \"deterministic_seek_to_first_packet_ns_per_operation\": {{"
    )
    .unwrap();
    writeln!(json, "      \"scope\": \"seek plus first selected packet retrieval over a fixed seeded target sequence\",").unwrap();
    writeln!(
        json,
        "      \"operations_per_repetition\": {},",
        config.seek_operations
    )
    .unwrap();
    writeln!(json, "      \"checksum\": \"{:016x}\",", seek.checksum).unwrap();
    writeln!(
        json,
        "      \"stats\": {}",
        integer_stats_json(&seek.per_operation_ns)
    )
    .unwrap();
    writeln!(json, "    }}").unwrap();
    writeln!(json, "  }},").unwrap();
    writeln!(
        json,
        "  \"external_reference\": {} ,",
        external_json(config, external)
    )
    .unwrap();
    writeln!(json, "  \"methodology\": {{").unwrap();
    writeln!(json, "    \"same_fixture\": true,").unwrap();
    writeln!(json, "    \"notes\": [").unwrap();
    writeln!(json, "      \"Open/index timing uses an in-memory ReadAt source and includes the Rust core's full metadata, cue, and cluster indexing pass.\",").unwrap();
    writeln!(json, "      \"Demux timing excludes session open and decoder work; it measures compressed packet parsing/copying only.\",").unwrap();
    writeln!(json, "      \"Seek timing includes seek resolution and retrieval of the first selected compressed packet; it does not decode or render.\",").unwrap();
    writeln!(json, "      \"ffprobe is an external-process, file-backed reference with process startup and different implementation scope; its values are not a direct win/loss comparison.\"").unwrap();
    writeln!(json, "    ]").unwrap();
    writeln!(json, "  }}").unwrap();
    writeln!(json, "}}").unwrap();
    json
}

fn integer_stats_json(stats: &IntegerStats) -> String {
    format!(
        "{{\"unit\":\"ns\",\"min\":{},\"median\":{:.3},\"mean\":{:.3},\"p95\":{},\"max\":{},\"samples\":[{}]}}",
        stats.min,
        stats.median,
        stats.mean,
        stats.p95,
        stats.max,
        stats
            .samples
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(",")
    )
}

fn float_stats_json(stats: &FloatStats) -> String {
    format!(
        "{{\"unit\":\"MiB/s\",\"min\":{:.6},\"median\":{:.6},\"mean\":{:.6},\"p95\":{:.6},\"max\":{:.6},\"samples\":[{}]}}",
        stats.min,
        stats.median,
        stats.mean,
        stats.p95,
        stats.max,
        stats
            .samples
            .iter()
            .map(|value| format!("{value:.6}"))
            .collect::<Vec<_>>()
            .join(",")
    )
}

fn external_json(config: &Config, external: Option<&ExternalBenchmark>) -> String {
    let Some(external) = external else {
        return "null".to_owned();
    };
    format!(
        "{{\"tool\":\"ffprobe\",\"path\":\"{}\",\"directly_comparable\":false,\"note\":\"External process with file I/O, startup, and different probing scope; reference only.\",\"metadata_process_elapsed_ns\":{},\"packet_scan_process_elapsed_ns\":{},\"metadata_stdout_bytes\":{},\"metadata_checksum\":\"{:016x}\",\"packet_scan_stdout_bytes\":{},\"packet_scan_checksum\":\"{:016x}\"}}",
        json_escape(
            &config
                .ffprobe
                .as_ref()
                .expect("external path")
                .display()
                .to_string()
        ),
        integer_stats_json(&external.metadata_process),
        integer_stats_json(&external.packet_scan_process),
        external.metadata_observation.stdout_bytes,
        external.metadata_observation.checksum,
        external.packet_scan_observation.stdout_bytes,
        external.packet_scan_observation.checksum,
    )
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            value if value.is_control() => write!(escaped, "\\u{:04x}", value as u32).unwrap(),
            value => escaped.push(value),
        }
    }
    escaped
}

#[allow(clippy::too_many_arguments)]
fn print_summary(
    config: &Config,
    fixture_path: &Path,
    fixture_bytes: usize,
    summary: &ContainerSummary,
    open: &IntegerStats,
    demux: &DemuxBenchmark,
    seek: &SeekBenchmark,
    external: Option<&ExternalBenchmark>,
) {
    println!(
        "Rust Matroska core benchmark ({})",
        if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        }
    );
    println!(
        "Fixture: {} ({:.2} MiB, {:.3} s, {} tracks, {} cues, {} clusters)",
        fixture_path.display(),
        fixture_bytes as f64 / MIB,
        summary.duration_ns as f64 / 1_000_000_000.0,
        summary.track_count,
        summary.cue_count,
        summary.cluster_count
    );
    println!(
        "Open + metadata/cue/cluster index: median {}, p95 {} ({} warmups, {} runs)",
        human_ns(open.median),
        human_ns(open.p95 as f64),
        config.warmups,
        config.repetitions
    );
    println!(
        "Full compressed-packet demux: {} packets / {:.2} MiB payload, median {} ({:.2} MiB/s payload)",
        demux.observation.packet_count,
        demux.observation.payload_bytes as f64 / MIB,
        human_ns(demux.elapsed.median),
        demux.payload_throughput_mib_s.median
    );
    println!(
        "Deterministic seek + first packet: median {} per operation ({} fixed targets/run)",
        human_ns(seek.per_operation_ns.median),
        config.seek_operations
    );
    if let Some(external) = external {
        println!(
            "ffprobe external-process reference: metadata median {}, full packet scan median {}",
            human_ns(external.metadata_process.median),
            human_ns(external.packet_scan_process.median)
        );
        println!(
            "  Reference only: includes process startup + file I/O and is not directly comparable to the in-process Rust measurements."
        );
    } else {
        println!("ffprobe external-process reference: not requested or unavailable");
    }
    println!("JSON: {}", config.json_output.display());
}

fn human_ns(nanoseconds: f64) -> String {
    if nanoseconds >= 1_000_000_000.0 {
        format!("{:.3} s", nanoseconds / 1_000_000_000.0)
    } else if nanoseconds >= 1_000_000.0 {
        format!("{:.3} ms", nanoseconds / 1_000_000.0)
    } else if nanoseconds >= 1_000.0 {
        format!("{:.3} us", nanoseconds / 1_000.0)
    } else {
        format!("{nanoseconds:.1} ns")
    }
}
