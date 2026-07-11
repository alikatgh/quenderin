#!/usr/bin/env python3
"""
codemod_stringres.py — replace hardcoded Compose literals with stringResource(R.string.id).

Only rewrites NON-interpolated literals, and only on lines that call a localizable
Compose API (Text/*Button/label=/placeholder=/contentDescription=/title=) — so a
bare "Share" in non-UI code is never touched. Interpolated strings are left for a
manual pass. Adds the stringResource + R imports to any file it changed.
Prints a per-file report; run from android/, then `git diff` before building.
"""
import re, os

# english -> resource id (non-interpolated only; must match gen_strings.RES)
IDMAP = {
 "Clear":"action_clear","Cancel":"action_cancel","Continue":"action_continue",
 "Delete":"action_delete","Share":"action_share","Stop":"action_stop","Run":"action_run",
 "Remove":"action_remove","Revoke":"action_revoke","Allow":"action_allow",
 "Don't allow":"action_dont_allow","Try again":"action_try_again","Get started":"action_get_started",
 "New chat":"chat_new","New conversation":"chat_new_conversation",
 "Back to conversations":"chat_back_to_conversations","More options":"chat_more_options",
 "Attach a file":"chat_attach_file","Continue generating from where the reply stopped":"chat_continue_generating",
 "Attach file":"agent_attach_file","Give the agent a goal":"agent_give_goal",
 "Allow this action?":"agent_allow_action_q","Download & continue":"onboarding_download_continue",
 "Choose a different model…":"onboarding_choose_different","Choose a smaller model":"onboarding_choose_smaller",
 "Ready.":"onboarding_ready","Couldn't get set up":"onboarding_setup_failed",
 "Change model…":"model_change","Deep thinking":"model_deep_thinking",
 "Deeper reasoning":"settings_deeper_reasoning","Clear learned skills":"settings_clear_skills",
 "Privacy Policy":"settings_privacy_policy","Contact support":"settings_contact_support",
 "Quenderin is open source — GitHub":"settings_open_source_github",
 "View the source on GitHub":"welcome_view_source","I understand and agree":"consent_agree",
 "Read the full terms":"consent_read_terms","on-device · private":"badge_on_device_private",
 "Hugging Face ↗":"link_hugging_face",
}

API = re.compile(r'(?:\bText|\bButton|\bOutlinedButton|\bTextButton|\bFilledTonalButton|label\s*=|placeholder\s*=|contentDescription\s*=|title\s*=)')
IMPORT_SR = "import androidx.compose.ui.res.stringResource"
IMPORT_R = "import ai.quenderin.app.R"

files = [os.path.join("app/src/main/kotlin/ai/quenderin/app/ui", f) for f in os.listdir("app/src/main/kotlin/ai/quenderin/app/ui") if f.endswith(".kt")]
total = 0
for path in files:
    lines = open(path, encoding="utf-8").read().split("\n")
    changed = 0
    for i, line in enumerate(lines):
        if not API.search(line):
            continue
        for en, rid in IDMAP.items():
            lit = '"' + en.replace("\\", "\\\\") + '"'
            # exact literal, not a substring of a longer literal or a $-template
            if lit in line and "$" not in line[line.find(lit):line.find(lit)+len(lit)+2]:
                lines[i] = line.replace(lit, f"stringResource(R.string.{rid})")
                line = lines[i]
                changed += 1
    if changed:
        src = "\n".join(lines)
        # add imports after the package line if missing
        if IMPORT_SR not in src:
            src = re.sub(r'(^package [^\n]+\n)', r'\1\n' + IMPORT_SR + "\n" + IMPORT_R + "\n", src, count=1)
        elif IMPORT_R not in src:
            src = re.sub(r'(^package [^\n]+\n)', r'\1\n' + IMPORT_R + "\n", src, count=1)
        open(path, "w", encoding="utf-8").write(src)
        print(f"{os.path.basename(path)}: {changed} replaced")
        total += changed
print(f"total: {total} replacements")
