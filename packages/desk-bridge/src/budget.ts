import type { Snapshot } from "./protocol.ts";
/** Serialize each bounded row once, off the host event handler. Leave envelope headroom. */
export function displayBudget(snapshot: Snapshot): Snapshot {
	const result = {
		...snapshot,
		omitted: { runs: 0, schedules: 0, inputs: 0, evidence: 0, usage: 0 },
	};
	// Preserve the original total display allowance when optional work metadata
	// is present. Whole-row omission remains visible; no larger wire frame.
	const reserve = (snapshot.governance ? Buffer.byteLength(JSON.stringify(snapshot.governance)) : 0) + (snapshot.missionDecisions ? Buffer.byteLength(JSON.stringify(snapshot.missionDecisions)) : 0) + (snapshot.intercomRelations ? Buffer.byteLength(JSON.stringify(snapshot.intercomRelations)) : 0);
	const ratio = Math.max(0, (52000 - reserve) / 52000);
	for (const [key, baseBudget] of [
		["runs", 14000],
		["schedules", 15000],
		["inputs", 6000],
		["evidence", 7000],
		["usage", 10000],
	] as const) {
		const budget = Math.floor(baseBudget * ratio);
		let bytes = 0,
			count = 0;
		for (const row of snapshot[key]) {
			const size = Buffer.byteLength(JSON.stringify(row)) + 1;
			if (bytes + size > budget) break;
			bytes += size;
			count++;
		}
		Object.assign(result, { [key]: snapshot[key].slice(0, count) });
		result.omitted[key] = snapshot[key].length - count;
	}
	if (result.omitted.runs) result.childCoverage = "partial";
	result.dropped += Object.values(result.omitted).reduce((a, b) => a + b, 0);
	return result;
}
