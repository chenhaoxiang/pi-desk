process.stdin.once("data", () => {
  process.stdout.write(JSON.stringify({ operation: "models", status: "error", code: "registry-unavailable" }) + "\n");
  process.stdin.destroy();
});
