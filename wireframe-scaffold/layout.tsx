import { redirect } from "next/navigation";

export default function WorkflowsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  // Only accessible in development/staging
  if (process.env.NODE_ENV === "production") {
    redirect("/");
  }

  return <>{children}</>;
}
