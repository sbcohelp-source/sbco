import type { NextConfig } from "next";
const desktop = process.env.SBCO_DESKTOP === "1";
const config: NextConfig = {
  distDir: desktop ? ".next-desktop" : ".next-web",
  transpilePackages: ["@sbco/features", "@sbco/ui", "@sbco/client"],
  ...(desktop
    ? { output: "export", images: { unoptimized: true } }
    : {
        output: "standalone",
        async rewrites() {
          return [
            {
              source: "/api/:path*",
              destination: `${process.env.SBCO_API_URL || "http://127.0.0.1:8091"}/api/:path*`,
            },
          ];
        },
      }),
};
export default config;
