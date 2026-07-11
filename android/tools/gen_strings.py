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
    # bottom navigation tabs (TSV rows: Chat / Agent / Settings)
    "tab_chat": "Chat",
    "tab_agent": "Agent",
    "tab_settings": "Settings",
    # first-run flow: welcome page (EXTRAS: phone-baked wording; iOS twin uses %@ device word)
    "welcome_title": "Meet Quenderin",
    "welcome_tagline": "A personal AI that lives on your phone — not in someone's cloud.",
    "welcome_private_title": "Private by design",
    "welcome_private_body": "Conversations never leave this phone. No account, no tracking.",
    "welcome_offline_title": "Works offline",
    "welcome_offline_body": "Download a model once — then it answers anywhere, airplane mode included.",
    "welcome_oss_title": "Open source",
    "welcome_oss_body": "Every line of Quenderin is public. Read it, star it, improve it.",
    # first-run flow: consent page (exact TSV rows — shared wording with iOS)
    "consent_use_judgement": "Use with judgement",
    "consent_wrong_title": "AI can be wrong",
    "consent_wrong_body": "On-device models are small. They can be confidently wrong, outdated, or occasionally inappropriate — and nothing filters them.",
    "consent_advice_title": "It is not advice",
    "consent_advice_body": "Nothing Quenderin writes is medical, legal, financial, or safety advice. Verify anything that matters with a qualified source.",
    "consent_charge_title": "You are in charge",
    "consent_charge_body": "Every answer is generated and acted on at your own risk and judgement — what you do with it is your decision alone.",
    "consent_legal": "By continuing you agree: Quenderin is provided “as is”, and to the maximum extent permitted by law, the Quenderin project and its contributors accept no liability, to anyone, under any circumstances, for the software or anything its AI models produce.",
    # first-run flow: onboarding hero + phases
    "onboarding_tagline": "An AI that runs on your phone — even offline.",
    "onboarding_private_line": "Private by design — no account, no cloud, no tracking.",
    "onboarding_checking": "Checking your device…",
    "onboarding_recommended_overline": "RECOMMENDED FOR YOUR DEVICE",
    "onboarding_free_up_storage": "Or free up storage and come back.",
    "onboarding_downloading": "Downloading",
    "onboarding_not_enough_space": "Not enough free space",
    # conversation list
    "chats_title": "Chats",
    "chats_empty_title": "No conversations yet",
    "chats_empty_body": "Start a chat with %1$s — it runs entirely on your phone.",
    # interpolated first-run strings
    "onboarding_size_one_time": "%1$s · one time, then it's yours offline",
    "onboarding_warming": "Warming up %1$s…",
    "onboarding_storage_needs": "This model needs ~%1$s GB — your phone has %2$s GB free.",
    "onboarding_downloading_a11y": "Downloading %1$s, %2$d percent",
    # interpolated (kept as Android format strings; args supplied at the call site)
    "agent_undo_last_move": "Undo last move (%1$d)",
    "chat_remove_named": "Remove %1$s",
    "chat_about_model": "About %1$s",
    "settings_delete_named": "Delete %1$s",
}

# Android-only strings (or wording that differs from any iOS key) — full 4-lang set.
EXTRAS = {
    # first-run flow (phone-baked variants of the iOS %@-device rows + format-string conversions)
    "A personal AI that lives on your phone — not in someone's cloud.":
        ("Персональный ИИ, который живёт на вашем телефоне — а не в чужом облаке.",
         "클라우드가 아닌 당신의 휴대폰 안에 사는 개인 AI.",
         "誰かのクラウドではなく、あなたのスマートフォンに住むパーソナルAI。",
         "住在你手机上的个人 AI——而不是别人的云端。"),
    "Private by design":
        ("Приватность по умолчанию", "설계부터 프라이버시", "設計からプライバシー重視", "隐私为本"),
    "Conversations never leave this phone. No account, no tracking.":
        ("Беседы не покидают этот телефон. Без аккаунта, без слежки.",
         "대화는 이 휴대폰을 떠나지 않습니다. 계정도, 추적도 없습니다.",
         "会話はこのスマートフォンから出ません。アカウントも追跡もなし。",
         "对话绝不离开这部手机。无账号，无跟踪。"),
    "Works offline":
        ("Работает офлайн", "오프라인에서 작동", "オフラインで動作", "离线可用"),
    "Download a model once — then it answers anywhere, airplane mode included.":
        ("Скачайте модель один раз — и она отвечает где угодно, даже в авиарежиме.",
         "모델을 한 번만 다운로드하면 비행기 모드에서도 어디서나 답합니다.",
         "モデルを一度ダウンロードすれば、機内モードでもどこでも答えます。",
         "模型只需下载一次——随处可答，飞行模式也不例外。"),
    "Open source":
        ("Открытый код", "오픈 소스", "オープンソース", "开源"),
    "Every line of Quenderin is public. Read it, star it, improve it.":
        ("Каждая строка Quenderin открыта. Читайте, ставьте звёзды, улучшайте.",
         "Quenderin의 모든 코드가 공개되어 있습니다. 읽고, 별을 누르고, 개선하세요.",
         "Quenderinのコードはすべて公開。読んで、スターを付けて、改善してください。",
         "Quenderin 的每一行代码都公开。欢迎阅读、加星、改进。"),
    "An AI that runs on your phone — even offline.":
        ("ИИ, который работает на вашем телефоне — даже офлайн.",
         "오프라인에서도 당신의 휴대폰에서 실행되는 AI.",
         "オフラインでもスマートフォン上で動くAI。",
         "即使离线也能在你的手机上运行的 AI。"),
    "Private by design — no account, no cloud, no tracking.":
        ("Приватность по умолчанию — без аккаунта, облака и слежки.",
         "설계부터 프라이버시 — 계정, 클라우드, 추적이 없습니다.",
         "プライバシー最優先の設計 — アカウントもクラウドも追跡もなし。",
         "隐私为本——无账号、无云端、无跟踪。"),
    "Or free up storage and come back.":
        ("Или освободите место и вернитесь.", "또는 저장 공간을 확보한 후 다시 시도하세요.",
         "または空き容量を確保してからもう一度。", "或者清理存储空间后再试。"),
    "Downloading":
        ("Загрузка", "다운로드 중", "ダウンロード中", "正在下载"),
    "Not enough free space":
        ("Недостаточно свободного места", "여유 공간이 부족합니다", "空き容量が足りません", "可用空间不足"),
    "%1$s · one time, then it's yours offline":
        ("%1$s · один раз — и модель ваша, офлайн", "%1$s · 한 번만 받으면 오프라인에서 계속 사용",
         "%1$s · 一度きり、その後はオフラインで利用可能", "%1$s · 一次下载，永久离线可用"),
    "Warming up %1$s…":
        ("Прогреваем %1$s…", "%1$s 준비 중…", "%1$sをウォームアップ中…", "正在预热 %1$s…"),
    "This model needs ~%1$s GB — your phone has %2$s GB free.":
        ("Этой модели нужно ~%1$s ГБ — на вашем телефоне свободно %2$s ГБ.",
         "이 모델에는 약 %1$s GB가 필요합니다 — 휴대폰에는 %2$s GB의 여유가 있습니다.",
         "このモデルには約%1$s GBが必要です — スマートフォンの空きは%2$s GBです。",
         "此模型需要约 %1$s GB——你的手机有 %2$s GB 可用。"),
    "Downloading %1$s, %2$d percent":
        ("Загрузка %1$s, %2$d процентов", "%1$s 다운로드 중, %2$d퍼센트",
         "%1$sをダウンロード中、%2$dパーセント", "正在下载 %1$s，%2$d％"),
    "Start a chat with %1$s — it runs entirely on your phone.":
        ("Начать чат с %1$s — модель работает полностью на вашем телефоне.",
         "%1$s와 채팅을 시작하세요 — 전부 당신의 휴대폰에서 실행됩니다.",
         "%1$sとチャットを始めましょう — すべてスマートフォン上で動作します。",
         "开始与 %1$s 聊天——它完全在你的手机上运行。"),
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
