import type { StorybookConfig } from "@storybook/react-vite";

const config: StorybookConfig = {
  stories: ["../src/**/*.stories.@(ts|tsx)"],
  addons: ["@storybook/addon-a11y"],
  framework: {
    name: "@storybook/react-vite",
    options: {},
  },
  viteFinal: async (viteConfig) => ({
    ...viteConfig,
    plugins: viteConfig.plugins?.filter(
      (plugin) =>
        !plugin ||
        typeof plugin !== "object" ||
        Array.isArray(plugin) ||
        !("name" in plugin) ||
        plugin.name !== "vivi-production-csp",
    ),
  }),
};

export default config;
