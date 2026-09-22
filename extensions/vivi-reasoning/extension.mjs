import { joinSession } from "@github/copilot-sdk/extension";

const REASONING_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/** @type {import("@github/copilot-sdk").CopilotSession} */
let session;
session = await joinSession({
  commands: [
    {
      name: "reasoning",
      description:
        "Show or change the current model's reasoning effort: none, minimal, low, medium, high, xhigh, or max.",
      handler: async ({ args }) => {
        const requested = args.trim().toLowerCase();
        if (requested.length === 0) {
          const current = await session.rpc.model.getCurrent();
          await session.log(
            `Reasoning effort: ${current.reasoningEffort ?? "model default"}. ` +
              `Use /reasoning ${REASONING_LEVELS.join("|")}.`,
          );
          return;
        }
        if (!REASONING_LEVELS.includes(requested)) {
          await session.log(
            `Unknown reasoning effort "${requested}". Choose ${REASONING_LEVELS.join(", ")}.`,
            { level: "warning" },
          );
          return;
        }

        await session.rpc.model.setReasoningEffort({
          reasoningEffort: requested,
        });
        await session.log(`Reasoning effort changed to ${requested}.`);
      },
    },
  ],
});
