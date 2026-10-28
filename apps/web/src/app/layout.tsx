import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = {
  title: "SBCO | Voucher verification",
  description: "SBCO imports, verification and correspondence",
};
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
