import { clerkMiddleware } from "@clerk/nextjs/server";

/**
 * Clerk on every page and API route. Pages that need a signed-in person call `auth.protect()` themselves (a session,
 * Devices, the device approval page); the landing page renders for everyone.
 */
export default clerkMiddleware({ signInUrl: "/sign-in", signUpUrl: "/sign-up" });

export const config = {
  matcher: [
    // Skip Next.js internals and static files, unless found in search params.
    "/((?!_next|[^?]*\\.(?:html?|css|js(?!on)|jpe?g|webp|png|gif|svg|ttf|woff2?|ico|csv|docx?|xlsx?|zip|webmanifest)).*)",
    // Always run for API routes.
    "/(api|trpc)(.*)",
  ],
};
