import { App } from "@sbco/features";
export function generateStaticParams() {
  return [
    "onboarding",
    "training",
    "help",
    "imports",
    "verify",
    "bo-verification",
    "agent-verification",
    "rd-default",
    "reverify",
    "corrections",
    "incidents",
    "letters",
    "reports",
    "offices",
    "users",
    "settings",
    "audit",
    "account",
  ].map((section) => ({ section }));
}
export const dynamicParams = false;
export default async function Page({ params }: { params: Promise<{ section: string }> }) {
  const { section } = await params;
  return <App section={section} />;
}
