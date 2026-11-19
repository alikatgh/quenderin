#!/usr/bin/env node
import { initializeBotWorkJournal } from '../quenderin-bot-work-journal.mjs';
const args = process.argv.slice(2);
if (args.length !== 1) { process.stderr.write('Usage: node initialize_bot_work_journal.mjs /absolute/new/private/journal-directory\n'); process.exitCode = 1; }
else {
  try { initializeBotWorkJournal(args[0]); process.stdout.write('QUENDERIN_BOT_WORK_JOURNAL_INITIALIZED\n'); }
  catch { process.stderr.write('Bot work journal setup refused; use a new absolute private path with real directory ancestors. Existing paths are never reset.\n'); process.exitCode = 1; }
}
