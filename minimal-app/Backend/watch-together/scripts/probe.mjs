import crypto from "node:crypto";
import { ConvexHttpClient } from "convex/browser";
import { api } from "../convex/_generated/api.js";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required (source .env.local first)");
const client = new ConvexHttpClient(deploymentUrl);
const secretA = crypto.randomBytes(32).toString("base64url");
const secretB = crypto.randomBytes(32).toString("base64url");
const suffix = Date.now().toString(36);

const a = await client.mutation(api.profiles.bootstrap, { deviceSecret: secretA, displayName: `Probe A ${suffix}` });
const b = await client.mutation(api.profiles.bootstrap, { deviceSecret: secretB, displayName: `Probe B ${suffix}` });
const request = await client.mutation(api.friends.sendRequest, { deviceSecret: secretA, friendCode: b.friendCode });
await client.mutation(api.friends.respond, { deviceSecret: secretB, requestId: request.requestId, accept: false });
const retriedRequest = await client.mutation(api.friends.sendRequest, { deviceSecret: secretA, friendCode: b.friendCode });
if (retriedRequest.requestId !== request.requestId) throw new Error("Declined friend request retry created a duplicate row");
await client.mutation(api.friends.respond, { deviceSecret: secretB, requestId: retriedRequest.requestId, accept: true });
const room = await client.mutation(api.rooms.create, { deviceSecret: secretA, contentKey: `movie:probe-${suffix}`, contentType: "movie", contentTitle: "Backend Probe" });
const firstInvite = await client.mutation(api.rooms.inviteFriend, { deviceSecret: secretA, roomId: room.id, friendProfileId: b.id });
await client.mutation(api.rooms.join, { deviceSecret: secretB, roomCode: room.code });
const retriedInvite = await client.mutation(api.rooms.inviteFriend, { deviceSecret: secretA, roomId: room.id, friendProfileId: b.id });
if (retriedInvite.inviteId !== firstInvite.inviteId) throw new Error("Accepted room invite retry created a duplicate row");
const update = await client.mutation(api.rooms.updatePlayback, { deviceSecret: secretB, roomId: room.id, position: 42, isPlaying: true, rate: 1, versionCounter: 1, versionActor: b.id, sentAt: Date.now() });
const stale = await client.mutation(api.rooms.updatePlayback, { deviceSecret: secretA, roomId: room.id, position: 2, isPlaying: false, rate: 1, versionCounter: 0, versionActor: a.id, sentAt: Date.now() });
const snapshot = await client.query(api.rooms.get, { deviceSecret: secretA, roomId: room.id });
if (!update.accepted || stale.accepted || !snapshot || snapshot.participants.length !== 2 || snapshot.playback.position < 42) {
  throw new Error(`Probe invariant failed: ${JSON.stringify({ update, stale, snapshot })}`);
}
await client.mutation(api.rooms.leave, { deviceSecret: secretB, roomId: room.id });
await client.mutation(api.rooms.leave, { deviceSecret: secretA, roomId: room.id });
console.log(JSON.stringify({ ok: true, projectUrl: deploymentUrl, roomCode: room.code, orderedSnapshot: snapshot.playback }, null, 2));
