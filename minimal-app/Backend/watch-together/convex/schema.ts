import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const playbackState = v.object({
  position: v.number(),
  isPlaying: v.boolean(),
  rate: v.number(),
  versionCounter: v.number(),
  versionActor: v.string(),
  updatedAt: v.number(),
});

export default defineSchema({
  profiles: defineTable({
    displayName: v.string(),
    friendCode: v.string(),
    secretHash: v.string(),
    createdAt: v.number(),
  })
    .index("by_secret_hash", ["secretHash"])
    .index("by_friend_code", ["friendCode"]),

  friendRequests: defineTable({
    fromProfileId: v.id("profiles"),
    toProfileId: v.id("profiles"),
    status: v.union(v.literal("pending"), v.literal("accepted"), v.literal("declined")),
    createdAt: v.number(),
    respondedAt: v.optional(v.number()),
  })
    .index("by_to_status", ["toProfileId", "status"])
    .index("by_pair", ["fromProfileId", "toProfileId"]),

  friendships: defineTable({
    leftProfileId: v.id("profiles"),
    rightProfileId: v.id("profiles"),
    createdAt: v.number(),
  })
    .index("by_left", ["leftProfileId"])
    .index("by_right", ["rightProfileId"])
    .index("by_pair", ["leftProfileId", "rightProfileId"]),

  rooms: defineTable({
    code: v.string(),
    hostProfileId: v.id("profiles"),
    livekitRoomName: v.string(),
    contentKey: v.string(),
    contentType: v.string(),
    contentTitle: v.string(),
    status: v.union(v.literal("active"), v.literal("closed")),
    playback: playbackState,
    createdAt: v.number(),
  })
    .index("by_code", ["code"])
    .index("by_host_status", ["hostProfileId", "status"]),

  roomParticipants: defineTable({
    roomId: v.id("rooms"),
    profileId: v.id("profiles"),
    joinedAt: v.number(),
    leftAt: v.optional(v.number()),
  })
    .index("by_room", ["roomId"])
    .index("by_room_profile", ["roomId", "profileId"])
    .index("by_profile", ["profileId"]),

  roomInvites: defineTable({
    roomId: v.id("rooms"),
    fromProfileId: v.id("profiles"),
    toProfileId: v.id("profiles"),
    status: v.union(v.literal("pending"), v.literal("accepted"), v.literal("declined")),
    createdAt: v.number(),
    respondedAt: v.optional(v.number()),
  })
    .index("by_to_status", ["toProfileId", "status"])
    .index("by_room_to", ["roomId", "toProfileId"]),
});
