Plan usage for the {{window}} window is at {{pct}}%. Resets in {{resets_in}} (at {{resets_at}}). Wind down now:
1. Finish or cleanly pause the current step. Don't start new work.
2. If subagents are running, tell them to stop and report what's done and outstanding.
3. Write a handoff to `{{handoff_path}}`: goal, done, in progress, next steps, open questions, relevant files.{{commit_step}}
4. If the reset is within {{resume_max_wait}} and you have a tool that can schedule a future prompt in this session, schedule one for just after {{resets_at}} saying: "Usage has reset. Read {{handoff_path}} and continue." Otherwise tell the user when usage resets and that the handoff is ready.
5. Tell the user what you did.
