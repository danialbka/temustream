import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { hashDeviceSecret, requireProfile } from "./auth";

const profileView = v.object({
  id: v.string(),
  displayName: v.string(),
  friendCode: v.string(),
});

function normalizeName(value: string) {
  const name = value.trim().replace(/\s+/g, " ");
  if (name.length < 2 || name.length > 40) {
    throw new ConvexError("Display name must be 2 to 40 characters");
  }
  return name;
}

export const bootstrap = mutation({
  args: { deviceSecret: v.string(), displayName: v.string() },
  returns: profileView,
  handler: async (ctx, args) => {
    const secretHash = await hashDeviceSecret(args.deviceSecret);
    const displayName = normalizeName(args.displayName);
    const existing = await ctx.db
      .query("profiles")
      .withIndex("by_secret_hash", query => query.eq("secretHash", secretHash))
      .unique();
    if (existing) {
      if (existing.displayName !== displayName) await ctx.db.patch(existing._id, { displayName });
      return { id: existing._id, displayName, friendCode: existing.friendCode };
    }

    const createdAt = Date.now();
    const id = await ctx.db.insert("profiles", {
      displayName,
      friendCode: "pending",
      secretHash,
      createdAt,
    });
    const compact = id.replace(/[^a-zA-Z0-9]/g, "").slice(-8).toUpperCase();
    const friendCode = `BUN-${compact}`;
    await ctx.db.patch(id, { friendCode });
    return { id, displayName, friendCode };
  },
});

export const me = query({
  args: { deviceSecret: v.string() },
  returns: profileView,
  handler: async (ctx, args) => {
    const profile = await requireProfile(ctx.db, args.deviceSecret);
    return { id: profile._id, displayName: profile.displayName, friendCode: profile.friendCode };
  },
});
