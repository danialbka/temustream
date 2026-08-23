"use node";

import { ConvexError, v } from "convex/values";
import { AccessToken, TrackSource } from "livekit-server-sdk";
import { api } from "./_generated/api";
import { action } from "./_generated/server";

type TokenAuthorization = {
  profileId: string;
  displayName: string;
  livekitRoomName: string;
};

type JoinTokenResult = {
  serverUrl: string;
  participantToken: string;
  expiresAt: number;
};

export const joinToken = action({
  args: { deviceSecret: v.string(), roomId: v.id("rooms") },
  returns: v.object({ serverUrl: v.string(), participantToken: v.string(), expiresAt: v.number() }),
  handler: async (ctx, args): Promise<JoinTokenResult> => {
    const auth: TokenAuthorization = await ctx.runQuery(api.rooms.tokenAuthorization, args);
    const serverUrl = process.env.LIVEKIT_URL;
    const apiKey = process.env.LIVEKIT_API_KEY;
    const apiSecret = process.env.LIVEKIT_API_SECRET;
    if (!serverUrl || !apiKey || !apiSecret) throw new ConvexError("LiveKit is not configured on this deployment");
    const ttlSeconds = 10 * 60;
    const token = new AccessToken(apiKey, apiSecret, { identity: auth.profileId, name: auth.displayName, ttl: ttlSeconds });
    token.addGrant({
      roomJoin: true,
      room: auth.livekitRoomName,
      canPublish: true,
      canPublishSources: [TrackSource.MICROPHONE],
      canSubscribe: true,
      canPublishData: true,
    });
    return { serverUrl, participantToken: await token.toJwt(), expiresAt: Date.now() + ttlSeconds * 1000 };
  },
});
