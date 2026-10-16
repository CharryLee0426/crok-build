import { SignUp } from "@clerk/nextjs";
import type { Metadata } from "next";
import { AuthFrame } from "@/components/AuthFrame";
import { pageTitle } from "@/lib/server-lang";

export async function generateMetadata(): Promise<Metadata> {
  return { title: await pageTitle("sign_in") };
}

/** First sign-in with GitHub or Google lands here when Clerk treats it as a sign-up. */
export default function SignUpPage() {
  return (
    <AuthFrame>
      <SignUp signInUrl="/sign-in" fallbackRedirectUrl="/" />
    </AuthFrame>
  );
}
