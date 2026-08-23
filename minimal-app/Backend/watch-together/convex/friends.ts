import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { areFriends, orderedPair, requireProfile } from "./auth";

const friendView = v.object({ id: v.string(), displayName: v.string() });
const requestView = v.object({
  id: v.string(),
  profileId: v.string(),
  displayName: v.string(),
  direction: v.union(v.literal("incoming"), v.literal("outgoing")),
});

export const list = query({
  args: { deviceSecret: v.string() },
  returns: v.object({ friends: v.array(friendView), requests: v.array(requestView) }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const [leftRows, rightRows, incoming, outgoing] = await Promise.all([
      ctx.db.query("friendships").withIndex("by_left", q => q.eq("leftProfileId", me._id)).collect(),
      ctx.db.query("friendships").withIndex("by_right", q => q.eq("rightProfileId", me._id)).collect(),
      ctx.db.query("friendRequests").withIndex("by_to_status", q => q.eq("toProfileId", me._id).eq("status", "pending")).collect(),
      ctx.db.query("friendRequests").filter(q => q.and(q.eq(q.field("fromProfileId"), me._id), q.eq(q.field("status"), "pending"))).collect(),
    ]);
    const friendIds = [...leftRows.map(row => row.rightProfileId), ...rightRows.map(row => row.leftProfileId)];
    const friends = (await Promise.all(friendIds.map(id => ctx.db.get(id))))
      .filter(profile => profile !== null)
      .map(profile => ({ id: profile!._id, displayName: profile!.displayName }))
      .sort((a, b) => a.displayName.localeCompare(b.displayName));
    const requests = await Promise.all([
      ...incoming.map(async row => {
        const profile = await ctx.db.get(row.fromProfileId);
        return profile && { id: row._id, profileId: profile._id, displayName: profile.displayName, direction: "incoming" as const };
      }),
      ...outgoing.map(async row => {
        const profile = await ctx.db.get(row.toProfileId);
        return profile && { id: row._id, profileId: profile._id, displayName: profile.displayName, direction: "outgoing" as const };
      }),
    ]);
    return { friends, requests: requests.filter(item => item !== null) };
  },
});

export const sendRequest = mutation({
  args: { deviceSecret: v.string(), friendCode: v.string() },
  returns: v.object({ requestId: v.string() }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const code = args.friendCode.trim().toUpperCase();
    const target = await ctx.db.query("profiles").withIndex("by_friend_code", q => q.eq("friendCode", code)).unique();
    if (!target) throw new ConvexError("Friend code not found");
    if (target._id === me._id) throw new ConvexError("You cannot add yourself");
    if (await areFriends(ctx.db, me._id, target._id)) throw new ConvexError("Already friends");
    const existing = await ctx.db.query("friendRequests").withIndex("by_pair", q => q.eq("fromProfileId", me._id).eq("toProfileId", target._id)).unique();
    if (existing) {
      if (existing.status !== "pending") {
        await ctx.db.patch(existing._id, {
          status: "pending",
          createdAt: Date.now(),
          respondedAt: undefined,
        });
      }
      return { requestId: existing._id };
    }
    const reverse = await ctx.db.query("friendRequests").withIndex("by_pair", q => q.eq("fromProfileId", target._id).eq("toProfileId", me._id)).unique();
    if (reverse?.status === "pending") throw new ConvexError("This person already sent you a request");
    const requestId = await ctx.db.insert("friendRequests", {
      fromProfileId: me._id,
      toProfileId: target._id,
      status: "pending",
      createdAt: Date.now(),
    });
    return { requestId };
  },
});

export const respond = mutation({
  args: { deviceSecret: v.string(), requestId: v.id("friendRequests"), accept: v.boolean() },
  returns: v.object({ accepted: v.boolean() }),
  handler: async (ctx, args) => {
    const me = await requireProfile(ctx.db, args.deviceSecret);
    const request = await ctx.db.get(args.requestId);
    if (!request || request.toProfileId !== me._id || request.status !== "pending") {
      throw new ConvexError("Friend request is unavailable");
    }
    const now = Date.now();
    await ctx.db.patch(request._id, { status: args.accept ? "accepted" : "declined", respondedAt: now });
    if (args.accept) {
      const pair = orderedPair(request.fromProfileId, request.toProfileId);
      const existing = await ctx.db.query("friendships").withIndex("by_pair", q => q.eq("leftProfileId", pair.leftProfileId).eq("rightProfileId", pair.rightProfileId)).unique();
      if (!existing) await ctx.db.insert("friendships", { ...pair, createdAt: now });
    }
    return { accepted: args.accept };
  },
});
