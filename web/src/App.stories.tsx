import type { Meta, StoryObj } from "@storybook/react-vite";
import { ViviApp } from "./App";
import { fixtures } from "./fixtures";
import { MockViviHost } from "./host/mock";

const meta = {
  title: "Vivi/Application",
  component: ViviApp,
  parameters: { layout: "fullscreen" },
} satisfies Meta<typeof ViviApp>;

export default meta;
type Story = StoryObj<typeof meta>;

const story = (
  fixture: keyof typeof fixtures,
  options: {
    appearance?: "light" | "dark";
    collapsed?: boolean;
  } = {},
): Story => ({
  args: {
    host: new MockViviHost(fixtures[fixture]),
    appearance: options.appearance,
    initiallyCollapsed:
      options.collapsed && fixtures[fixture].projects[0]
        ? [fixtures[fixture].projects[0].path]
        : [],
  },
});

export const EmptyApp = story("empty");
export const OneProjectOneSession = story("one");
export const MultipleProjects = story("multiple");
export const DuplicateUntitledSessions = story("multiple");
export const LongTitlesAndPaths = story("longTitles");
export const CollapsedProject = story("multiple", { collapsed: true });
export const SelectedBottomRow: Story = {
  args: {
    host: new MockViviHost({
      ...fixtures.multiple,
      projects: fixtures.multiple.projects,
      selectedSession: {
        id: fixtures.multiple.projects[0]!.sessions[2]!.id,
        activeWorkspace: fixtures.multiple.projects[0]!.path,
        transcript: [],
        error: null,
      },
    }),
  },
};
export const StreamingResponse = story("streaming");
export const ReasoningAndToolSequence = story("one");
export const ErrorStates = story("error");
export const DarkAppearance = story("multiple", { appearance: "dark" });
