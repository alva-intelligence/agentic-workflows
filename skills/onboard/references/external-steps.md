## Steps requiring sudo or external terminal

Some steps (Nix installation, system config changes, etc.) require `sudo` or an interactive terminal that the agent cannot provide. For these:

1. **Tell the user exactly what to run** in a separate terminal
2. **Use the ask tool** to ask if they've completed it
3. **DO NOT proceed** until user confirms — use the ask tool to block
4. **Verify** the step actually worked (e.g., `command -v nix`) before moving on
5. If verification fails, ask again — do NOT skip the step
