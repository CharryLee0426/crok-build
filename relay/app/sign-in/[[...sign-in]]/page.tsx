import { SignIn } from "@clerk/nextjs";
import type { Metadata } from "next";
import { AuthFrame } from "@/components/AuthFrame";
import { pageTitle } from "@/lib/server-lang";

export async function generateMetadata(): Promise<Metadata> {
  return { title: await pageTitle("sign_in") };
}

/** GitHub or Google (the connections enabled in Clerk). `redirect_url` brings the person back, e.g. to /link?code=…. */
export default function SignInPage() {
  return (
    <AuthFrame>
      <SignIn signUpUrl="/sign-up" fallbackRedirectUrl="/" />
    </AuthFrame>
  );
}
