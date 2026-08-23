import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { areFriends, requireActiveParticipant, requireProfile } from "./auth";

const playbackView = v.object({
  position: v.number(),
  isPlaying: v.boolean(),
  rate: v.number(),
  versionCounter: v.number(),
  versionActor: v.string(),
  updatedAt: v.number(),
});
const participantView = v.object({ id: v.string(), displayName: v.string(), isHost: v.boolean() });
const roomView = v.object({
  id: v.string(), code: v.string(), hostProfileId: v.string(), contentKey: v.string(),
  contentType: v.string(), contentTitle: v.string(), playback: playbackView,
  participants: v.array(participantView),
});
const inviteView = v.object({ id: v.string(), roomId: v.string(), roomCode: v.string(), contentTitle: v.string(), fromDisplayName: v.string() });

function validateContent(key: string, type: string, title: string) {
  const cleanKey = key.trim();
  const cleanType = type.trim();
  const cleanTitle = title.trim();
  if (cleanKey.length < 2 || cleanKey.length > 180 || cleanType.length < 2 || cleanType.length > 32 || cleanTitle.length < 1 || cleanTitle.length > 180) {
    throw new ConvexError("Invalid content identity");
  }
  return { cleanKey, cleanType, cleanTitle };
}

async function buildRoomView(ctx: any, room: any) {
  const rows = await ctx.db.query("roomParticipants").withIndex("by_room", (q: any) => q.eq("roomId", room._id)).collect();
  const active = rows.filter((row: any) => row.leftAt === undefined);
  const participants = (await Promise.all(active.map(async (row: any) => {
    const profile = await ctx.db.get(row.profileId);
    return profile && { id: profile._id, displayName: profile.displayName, isHost: profile._id === room.hostProfileId };
  }))).filter((item: any) => item !== null);
  return {
    id: room._id, code: room.code, hostProfileId: room.hostProfileId,
    contentKey: room.contentKey, contentType: room.contentType, contentTitle: room.contentTitle,
    playback: room.playback, participants,
  };
}

export const create = mutation({
  args: { deviceSecret: v.string(), contentKey: v.string(), contentType: v.string(), contentTitle: v.string() },
  returns: roomView,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const content = validateContent(args.contentKey, args.contentType, args.contentTitle);
    const now = Date.now();
    const roomId = await ctx.db.insert("rooms", {
      code: "pending", hostProfileId: me._id, livekitRoomName: "pending",
      contentKey: content.cleanKey, contentType: content.cleanType, contentTitle: content.cleanTitle,
      status: "active", playback: { position: 0, isPlaying: false, rate: 1, versionCounter: 0, versionActor: me._id, updatedAt: now }, createdAt: now,
    });
    const compact = roomId.replace(/[^a-zA-Z0-9]/g, "").slice(-8).toUpperCase();
    await ctx.db.patch(roomId, { code: `ROOM-${compact}`, livekitRoomName: `temustream-${roomId}` });
    await ctx.db.insert("roomParticipants", { roomId, profileId: me._id, joinedAt: now });
    return await buildRoomView(ctx, (await ctx.db.get(roomId))!);
  },
});

export const inviteFriend = mutation({
  args: { deviceSecret: v.string(), roomId: v.id("rooms"), friendProfileId: v.id("profiles") },
  returns: v.object({ inviteId: v.string() }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const room = await ctx.db.get(args.roomId);
    if (!room || room.status !== "active" || room.hostProfileId !== me._id) throw new ConvexError("Only the room host can invite friends");
    if (!(await areFriends(ctx.db, me._id, args.friendProfileId))) throw new ConvexError("You can only invite a friend");
    const existing = await ctx.db.query("roomInvites").withIndex("by_room_to", q => q.eq("roomId", room._id).eq("toProfileId", args.friendProfileId)).unique();
    if (existing) {
      if (existing.status !== "pending") {
        await ctx.db.patch(existing._id, {
          status: "pending",
          fromProfileId: me._id,
          createdAt: Date.now(),
          respondedAt: undefined,
        });
      }
      return { inviteId: existing._id };
    }
    const inviteId = await ctx.db.insert("roomInvites", { roomId: room._id, fromProfileId: me._id, toProfileId: args.friendProfileId, status: "pending", createdAt: Date.now() });
    return { inviteId };
  },
});

export const invitations = query({
  args: { deviceSecret: v.string() },
  returns: v.array(inviteView),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const rows = await ctx.db.query("roomInvites").withIndex("by_to_status", q => q.eq("toProfileId", me._id).eq("status", "pending")).collect();
    const values = await Promise.all(rows.map(async invite => {
      const [room, from] = await Promise.all([ctx.db.get(invite.roomId), ctx.db.get(invite.fromProfileId)]);
      if (!room || room.status !== "active" || !from) return null;
      return { id: invite._id, roomId: room._id, roomCode: room.code, contentTitle: room.contentTitle, fromDisplayName: from.displayName };
    }));
    return values.filter(value => value !== null);
  },
});

export const join = mutation({
  args: { deviceSecret: v.string(), roomCode: v.string() },
  returns: roomView,
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const code = args.roomCode.trim().toUpperCase();
    const room = await ctx.db.query("rooms").withIndex("by_code", q => q.eq("code", code)).unique();
    if (!room || room.status !== "active") throw new ConvexError("Watch room not found");
    if (room.hostProfileId !== me._id && !(await areFriends(ctx.db, me._id, room.hostProfileId))) throw new ConvexError("Only friends of the host can join this room");
    const existing = await ctx.db.query("roomParticipants").withIndex("by_room_profile", q => q.eq("roomId", room._id).eq("profileId", me._id)).unique();
    if (existing) await ctx.db.patch(existing._id, { leftAt: undefined, joinedAt: Date.now() });
    else await ctx.db.insert("roomParticipants", { roomId: room._id, profileId: me._id, joinedAt: Date.now() });
    const invite = await ctx.db.query("roomInvites").withIndex("by_room_to", q => q.eq("roomId", room._id).eq("toProfileId", me._id)).unique();
    if (invite?.status === "pending") await ctx.db.patch(invite._id, { status: "accepted", respondedAt: Date.now() });
    return await buildRoomView(ctx, room);
  },
});

export const get = query({
  args: { deviceSecret: v.string(), roomId: v.id("rooms") },
  returns: v.union(roomView, v.null()),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const room = await ctx.db.get(args.roomId);
    if (!room || room.status !== "active") return null;
    await requireActiveParticipant(ctx.db, room._id, me._id);
    return await buildRoomView(ctx, room);
  },
});

export const updatePlayback = mutation({
  args: { deviceSecret: v.string(), roomId: v.id("rooms"), position: v.number(), isPlaying: v.boolean(), rate: v.number(), versionCounter: v.number(), versionActor: v.string(), sentAt: v.number() },
  returns: v.object({ accepted: v.boolean(), playback: playbackView }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const room = await ctx.db.get(args.roomId);
    if (!room || room.status !== "active") throw new ConvexError("Watch room unavailable");
    await requireActiveParticipant(ctx.db, room._id, me._id);
    if (args.versionActor !== me._id || !Number.isSafeInteger(args.versionCounter) || args.versionCounter < 0 || !Number.isFinite(args.position) || args.position < 0 || !Number.isFinite(args.rate) || args.rate < 0.25 || args.rate > 4) throw new ConvexError("Invalid playback snapshot");
    const current = room.playback;
    const newer = args.versionCounter > current.versionCounter || (args.versionCounter === current.versionCounter && args.versionActor > current.versionActor);
    if (!newer) return { accepted: false, playback: current };
    const now = Date.now();
    const transportAge = Math.max(0, Math.min(now - args.sentAt, 30_000));
    const playback = { position: args.position + (args.isPlaying ? (transportAge / 1000) * args.rate : 0), isPlaying: args.isPlaying, rate: args.rate, versionCounter: args.versionCounter, versionActor: args.versionActor, updatedAt: now };
    await ctx.db.patch(room._id, { playback });
    return { accepted: true, playback };
  },
});

export const leave = mutation({
  args: { deviceSecret: v.string(), roomId: v.id("rooms") },
  returns: v.object({ closed: v.boolean() }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const room = await ctx.db.get(args.roomId);
    if (!room) return { closed: true };
    const participant = await ctx.db.query("roomParticipants").withIndex("by_room_profile", q => q.eq("roomId", room._id).eq("profileId", me._id)).unique();
    if (participant && participant.leftAt === undefined) await ctx.db.patch(participant._id, { leftAt: Date.now() });
    if (room.hostProfileId === me._id) await ctx.db.patch(room._id, { status: "closed" });
    return { closed: room.hostProfileId === me._id };
  },
});

export const tokenAuthorization = query({
  args: { deviceSecret: v.string(), roomId: v.id("rooms") },
  returns: v.object({ profileId: v.string(), displayName: v.string(), livekitRoomName: v.string() }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const room = await ctx.db.get(args.roomId);
    if (!room || room.status !== "active") throw new ConvexError("Watch room unavailable");
    await requireActiveParticipant(ctx.db, room._id, me._id);
    return { profileId: me._id, displayName: me.displayName, livekitRoomName: room.livekitRoomName };
  },
});
