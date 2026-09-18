import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ViviApp } from "./App";
import { fixtures, resolveFixtureName } from "./fixtures";
import { MockViviHost } from "./host/mock";
import "./styles.css";

const scenario = new URLSearchParams(window.location.search).get("scenario");
const fixtureName = resolveFixtureName(scenario);
const hostPort = new MockViviHost(fixtures[fixtureName]);
const root = createRoot(document.getElementById("root")!);

void hostPort
  .connect()
  .then((host) => {
    root.render(
      <StrictMode>
        <ViviApp host={host} />
      </StrictMode>,
    );
  })
  .catch((error: unknown) => {
    const message =
      error instanceof Error ? error.message : "The host bridge did not start.";
    root.render(
      <main className="startup-error" role="alert">
        <strong>Vivi could not connect to its host.</strong>
        <span>{message}</span>
      </main>,
    );
  });
