// The names the agent-readiness states carry next to an agent, in the user's language. Kept apart
// from agentReadiness.ts so that pure module stays importable from Node's test runner, which has no
// Svelte runes.
import { t } from "./i18n/state.svelte";

export function readinessLabels(): Record<"needsSignIn" | "unavailable" | "unverified", string> {
	return {
		needsSignIn: t("agents.readiness.needsSignIn"),
		unavailable: t("agents.readiness.unavailable"),
		unverified: t("agents.readiness.unverified"),
	};
}
