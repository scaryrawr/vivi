import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ViviApp } from "./App";
import { fixtures, type FixtureName } from "./fixtures";
import { MockViviHost } from "./host/mock";
import "./styles.css";

const scenario = new URLSearchParams(window.location.search).get("scenario");
const fixtureName: FixtureName =
  scenario && scenario in fixtures ? (scenario as FixtureName) : "multiple";
const host = new MockViviHost(fixtures[fixtureName]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ViviApp host={host} />
  </StrictMode>,
);
