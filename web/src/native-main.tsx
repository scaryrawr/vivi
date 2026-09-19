import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ViviApp } from "./App";
import { NativeViviHostPort } from "./host/native";
import "./styles.css";

const root = createRoot(document.getElementById("root")!);

void new NativeViviHostPort()
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
