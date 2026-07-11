#!/usr/bin/env python3
"""
gen_strings.py — generate Android string resources for en + ru/ko/ja/zh-Hans.

Source of truth for translations is ../../scripts/translations.tsv (the same file
that drives iOS Localizable.xcstrings). English strings that match a TSV key reuse
those translations; Android-only strings use the EXTRAS dict below.

Emits: app/src/main/res/values{,-ru,-ko,-ja,-zh-rCN}/strings.xml
Resource ids come from RES (id -> english). %1$s/%1$d format strings are declared
here verbatim so aapt/lint validate specifier parity across every locale.
"""
import os, re, html

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
TSV = os.path.join(ROOT, "scripts", "translations.tsv")
RESDIR = os.path.join(os.path.dirname(__file__), "..", "app", "src", "main", "res")
LANGS = [("ru", 1), ("ko", 2), ("ja", 3), ("zh-rCN", 4)]  # tsv col index

# id -> English source (the real user-facing literals; animation labels excluded)
RES = {
    "action_clear": "Clear",
    "action_cancel": "Cancel",
    "action_continue": "Continue",
    "action_delete": "Delete",
    "action_share": "Share",
    "action_stop": "Stop",
    "action_run": "Run",
    "action_remove": "Remove",
    "action_revoke": "Revoke",
    "action_allow": "Allow",
    "action_dont_allow": "Don't allow",
    "action_try_again": "Try again",
    "action_get_started": "Get started",
    "chat_new": "New chat",
    "chat_new_conversation": "New conversation",
    "chat_back_to_conversations": "Back to conversations",
    "chat_more_options": "More options",
    "chat_attach_file": "Attach a file",
    "chat_continue_generating": "Continue generating from where the reply stopped",
    "agent_attach_file": "Attach file",
    "agent_give_goal": "Give the agent a goal",
    "agent_allow_action_q": "Allow this action?",
    "onboarding_download_continue": "Download & continue",
    "onboarding_choose_different": "Choose a different model…",
    "onboarding_choose_smaller": "Choose a smaller model",
    "onboarding_ready": "Ready.",
    "onboarding_setup_failed": "Couldn't get set up",
    "model_change": "Change model…",
    "model_deep_thinking": "Deep thinking",
    "settings_deeper_reasoning": "Deeper reasoning",
    "settings_clear_skills": "Clear learned skills",
    "settings_privacy_policy": "Privacy Policy",
    "settings_contact_support": "Contact support",
    "settings_open_source_github": "Quenderin is open source — GitHub",
    "welcome_view_source": "View the source on GitHub",
    "consent_agree": "I understand and agree",
    "consent_read_terms": "Read the full terms",
    "badge_on_device_private": "on-device · private",
    "link_hugging_face": "Hugging Face ↗",
    # interpolated (kept as Android format strings; args supplied at the call site)
    "agent_undo_last_move": "Undo last move (%1$d)",
    "chat_remove_named": "Remove %1$s",
    "chat_about_model": "About %1$s",
    "settings_delete_named": "Delete %1$s",
}

# Android-only strings (or wording that differs from any iOS key) — full 4-lang set.
EXTRAS = {
    "Try again":        ("Повторить", "다시 시도", "再試行", "重试"),
    "Get started":      ("Начать", "시작하기", "始める", "开始"),
    "New conversation": ("Новая беседа", "새 대화", "新しい会話", "新对话"),
    "Back to conversations": ("Назад к беседам", "대화 목록으로", "会話一覧に戻る", "返回对话列表"),
    "More options":     ("Ещё", "더 보기", "その他", "更多选项"),
    "Attach file":      ("Прикрепить файл", "파일 첨부", "ファイルを添付", "附加文件"),
    "Allow this action?": ("Разрешить это действие?", "이 동작을 허용할까요?", "この操作を許可しますか？", "允许此操作？"),
    "Allow":            ("Разрешить", "허용", "許可", "允许"),
    "Ready.":           ("Готово.", "준비됨.", "準備完了。", "已就绪。"),
    "Deep thinking":    ("Глубокое размышление", "심층 사고", "深い思考", "深度思考"),
    "Clear learned skills": ("Очистить выученные навыки", "학습된 스킬 지우기", "学習したスキルを消去", "清除已学技能"),
    "Quenderin is open source — GitHub": ("Quenderin — открытый код: GitHub", "Quenderin은 오픈소스입니다 — GitHub", "Quenderinはオープンソース — GitHub", "Quenderin 是开源的——GitHub"),
    "Hugging Face ↗":   ("Hugging Face ↗", "Hugging Face ↗", "Hugging Face ↗", "Hugging Face ↗"),
    "Undo last move (%1$d)": ("Отменить последнее перемещение (%1$d)", "마지막 이동 취소 (%1$d)", "直前の移動を取り消す（%1$d）", "撤销上一次移动（%1$d）"),
    "Remove %1$s":      ("Убрать %1$s", "%1$s 제거", "%1$sを削除", "移除 %1$s"),
    "About %1$s":       ("О модели %1$s", "%1$s 정보", "%1$sについて", "关于 %1$s"),
    "Delete %1$s":      ("Удалить %1$s", "%1$s 삭제", "%1$sを削除", "删除 %1$s"),
    "Attach a file":    ("Прикрепить файл", "파일 첨부", "ファイルを添付", "附加文件"),
    "Remove":           ("Убрать", "제거", "削除", "移除"),
    "Revoke":           ("Отозвать", "취소", "取り消す", "撤销"),
    "Run":              ("Запустить", "실행", "実行", "运行"),
    "Share":            ("Поделиться", "공유", "共有", "分享"),
}

# load TSV (english -> [ru,ko,ja,zh])
tsv = {}
for line in open(TSV, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    c = line.rstrip("\n").split("\t")
    if len(c) == 5:
        tsv[c[0]] = c[1:]

def esc(s):
    # XML-escape + Android apostrophe rule
    s = html.escape(s, quote=False)
    return s.replace("'", "\\'").replace('"', '\\"')

def translations_for(en):
    if en in EXTRAS:
        return dict(zip(("ru", "ko", "ja", "zh-rCN"), EXTRAS[en]))
    if en in tsv:
        return dict(zip(("ru", "ko", "ja", "zh-rCN"), tsv[en]))
    return None

def write_xml(path, pairs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out = ['<?xml version="1.0" encoding="utf-8"?>', "<resources>"]
    for rid, val in pairs:
        fmt = ' formatted="false"' if ("%" in val and "$" not in val) else ""
        out.append(f'    <string name="{rid}"{fmt}>{esc(val)}</string>')
    out.append("</resources>\n")
    open(path, "w", encoding="utf-8").write("\n".join(out))

# English base
write_xml(os.path.join(RESDIR, "values", "strings.xml"), list(RES.items()))

missing = []
for lang, idx in LANGS:
    pairs = []
    for rid, en in RES.items():
        t = translations_for(en)
        if t is None:
            missing.append(en); continue
        pairs.append((rid, t[lang]))
    write_xml(os.path.join(RESDIR, f"values-{lang}", "strings.xml"), pairs)

if missing:
    print("MISSING translations (add to EXTRAS):")
    for m in sorted(set(missing)):
        print("   ", repr(m))
else:
    print(f"wrote en + {len(LANGS)} locales, {len(RES)} strings each")
