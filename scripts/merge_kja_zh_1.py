#!/usr/bin/env python3
"""Chunk 1/3: fill ko/ja/zh-Hans columns in scripts/translations.tsv (keys A–G).
Exact-key merge; unmatched keys are reported, never guessed."""
import os

T = {
 "A one-time download — the main window shows progress and you can cancel any time. Your current model stays installed.":
   ("한 번만 다운로드하면 됩니다 — 진행 상황은 기본 창에 표시되며 언제든 취소할 수 있습니다. 현재 모델은 그대로 유지됩니다.",
    "ダウンロードは一度だけ — 進行状況はメインウィンドウに表示され、いつでもキャンセルできます。現在のモデルはそのまま残ります。",
    "只需下载一次——主窗口会显示进度，随时可以取消。当前模型保持不变。"),
 "A personal AI that lives on your %@ — not in someone's cloud.":
   ("클라우드가 아닌 당신의 %@ 안에 사는 개인 AI.",
    "誰かのクラウドではなく、あなたの%@に住むパーソナルAI。",
    "住在你的%@上的个人 AI——而不是别人的云端。"),
 "About Quenderin": ("Quenderin 정보", "Quenderinについて", "关于 Quenderin"),
 "About Quenderin — settings, help, and links":
   ("Quenderin 정보 — 설정, 도움말, 링크", "Quenderinについて — 設定・ヘルプ・リンク", "关于 Quenderin——设置、帮助与链接"),
 "About %@": ("%@ 정보", "%@について", "关于 %@"),
 "Accept the license on Hugging Face, then download it there":
   ("Hugging Face에서 라이선스에 동의한 뒤 그곳에서 다운로드하세요",
    "Hugging Faceでライセンスに同意し、そこでダウンロードしてください",
    "请先在 Hugging Face 接受许可，然后在那里下载"),
 "Actions for %@": ("%@ 관련 동작", "%@の操作", "%@ 的操作"),
 "Active": ("사용 중", "使用中", "使用中"),
 "Active — in use": ("활성 — 사용 중", "アクティブ — 使用中", "已启用——使用中"),
 "Active — protected": ("활성 — 보호됨", "アクティブ — 保護中", "已启用——受保护"),
 "Agent": ("에이전트", "エージェント", "智能体"),
 "Agent activity": ("에이전트 활동", "エージェントの活動", "智能体活动"),
 "Agent capabilities": ("에이전트 기능", "エージェントの機能", "智能体能力"),
 "All of these run fully on your %@ — a one-time download, then it's yours offline.":
   ("모두 당신의 %@에서 완전히 실행됩니다 — 한 번만 다운로드하면 오프라인에서 계속 사용할 수 있습니다.",
    "これらはすべて%@上で完全に動作します — 一度ダウンロードすれば、あとはオフラインで使えます。",
    "这些全部在你的%@上运行——下载一次，之后离线可用。"),
 "Allow %@": ("%@ 허용", "%@を許可", "允许 %@"),
 "Allow all steps for this goal": ("이 목표의 모든 단계 허용", "この目標のすべてのステップを許可", "允许此目标的所有步骤"),
 "Allow downloads over cellular": ("셀룰러 데이터로 다운로드 허용", "モバイル通信でのダウンロードを許可", "允许使用蜂窝数据下载"),
 "Allow this action": ("이 동작 허용", "この操作を許可", "允许此操作"),
 "Always on": ("항상 켜짐", "常にオン", "始终开启"),
 "An AI that runs on your %@ — even offline.":
   ("오프라인에서도 당신의 %@에서 실행되는 AI.", "オフラインでも%@上で動くAI。", "即使离线也能在你的%@上运行的 AI。"),
 "Appearance": ("모양", "外観", "外观"),
 "Ask Quenderin anything": ("Quenderin에게 무엇이든 물어보세요", "Quenderinに何でも聞いてください", "向 Quenderin 提问任何问题"),
 "Attach a file": ("파일 첨부", "ファイルを添付", "附加文件"),
 "Attach a file the agent may read (with your permission)":
   ("에이전트가 읽을 수 있는 파일 첨부 (당신의 허가 필요)",
    "エージェントが読めるファイルを添付（あなたの許可が必要）",
    "附加智能体可读取的文件（需你许可）"),
 "Attach a text file to this message":
   ("이 메시지에 텍스트 파일 첨부", "このメッセージにテキストファイルを添付", "为此消息附加文本文件"),
 "Autopilot": ("자동 진행", "オートパイロット", "自动驾驶"),
 "Back to model choice": ("모델 선택으로 돌아가기", "モデル選択に戻る", "返回模型选择"),
 "Balanced": ("균형", "バランス", "均衡"),
 "Browse or switch conversations from the sidebar in Chat.":
   ("채팅의 사이드바에서 대화를 탐색하거나 전환하세요.", "チャットのサイドバーから会話を閲覧・切り替えできます。", "在聊天侧边栏中浏览或切换对话。"),
 "Cancel": ("취소", "キャンセル", "取消"),
 "Cancel download": ("다운로드 취소", "ダウンロードをキャンセル", "取消下载"),
 "Change model…": ("모델 변경…", "モデルを変更…", "更换模型…"),
 "Chat": ("채팅", "チャット", "聊天"),
 "Chat can’t run this —": ("채팅에서는 실행할 수 없습니다 —", "チャットでは実行できません —", "聊天无法执行此操作——"),
 "Chat font": ("채팅 글꼴", "チャットのフォント", "聊天字体"),
 "Chats": ("채팅", "チャット", "聊天"),
 "Checking your device…": ("기기를 확인하는 중…", "デバイスを確認中…", "正在检查你的设备…"),
 "Choose a different model…": ("다른 모델 선택…", "別のモデルを選ぶ…", "选择其他模型…"),
 "Choose a model": ("모델 선택", "モデルを選ぶ", "选择模型"),
 "Choose a smaller model": ("더 작은 모델 선택", "より小さいモデルを選ぶ", "选择更小的模型"),
 "Clear": ("지우기", "消去", "清除"),
 "Clear all conversations…": ("모든 대화 지우기…", "すべての会話を消去…", "清除所有对话…"),
 "Clear recent goals": ("최근 목표 지우기", "最近の目標を消去", "清除最近目标"),
 "Clear run": ("실행 기록 지우기", "実行ログを消去", "清除运行记录"),
 "Clear search": ("검색 지우기", "検索を消去", "清除搜索"),
 "Community GGUFs — expand a row, pick a file size, then Get.":
   ("커뮤니티 GGUF — 행을 펼치고 파일 크기를 고른 뒤 받기를 누르세요.",
    "コミュニティGGUF — 行を開き、ファイルサイズを選んで「入手」を押してください。",
    "社区 GGUF——展开一行，选择文件大小，然后点击获取。"),
 "Contact support": ("지원팀에 문의", "サポートに問い合わせ", "联系支持"),
 "Continue": ("계속", "続ける", "继续"),
 "Continue generating from where the reply stopped":
   ("중단된 지점부터 이어서 생성", "止まったところから生成を続ける", "从中断处继续生成"),
 "Copy": ("복사", "コピー", "复制"),
 "Copy SHA-256": ("SHA-256 복사", "SHA-256をコピー", "复制 SHA-256"),
 "Copy answer": ("답변 복사", "回答をコピー", "复制回答"),
 "Copy file name": ("파일 이름 복사", "ファイル名をコピー", "复制文件名"),
 "Couldn't get set up": ("설정을 완료하지 못했습니다", "セットアップできませんでした", "设置未能完成"),
 "Curated models — tap Install to download, or Use if it’s already on disk.":
   ("엄선된 모델 — 설치를 눌러 다운로드하거나, 이미 디스크에 있으면 사용을 누르세요.",
    "厳選モデル — 「インストール」でダウンロード、ディスクにあれば「使う」を押してください。",
    "精选模型——点按安装以下载；若已在磁盘上，点按使用。"),
 "Current": ("현재", "現在", "当前"),
 "Deeper reasoning": ("더 깊은 추론", "より深い推論", "更深入的推理"),
 "Delete": ("삭제", "削除", "删除"),
 "Delete %@ chats…": ("채팅 %@개 삭제…", "%@件のチャットを削除…", "删除 %@ 个聊天…"),
 "Delete all": ("모두 삭제", "すべて削除", "全部删除"),
 "Delete all %lld conversations?": ("대화 %lld개를 모두 삭제할까요?", "%lld件の会話をすべて削除しますか？", "删除全部 %lld 个对话？"),
 "Delete…": ("삭제…", "削除…", "删除…"),
 "Density": ("밀도", "密度", "密度"),
 "Dismiss": ("닫기", "閉じる", "关闭"),
 "Dismiss suggestion": ("제안 닫기", "提案を閉じる", "关闭建议"),
 "Don't allow": ("허용 안 함", "許可しない", "不允许"),
 "Done": ("완료", "完了", "完成"),
 "Download": ("다운로드", "ダウンロード", "下载"),
 "Download & continue": ("다운로드 후 계속", "ダウンロードして続行", "下载并继续"),
 "Download all": ("모두 다운로드", "すべてダウンロード", "全部下载"),
 "Download the complete library (%@)": ("전체 라이브러리 다운로드 (%@)", "ライブラリ全体をダウンロード（%@）", "下载完整库（%@）"),
 "Downloaded models": ("다운로드된 모델", "ダウンロード済みモデル", "已下载的模型"),
 "Downloading · %lld%": ("다운로드 중 · %lld%", "ダウンロード中 · %lld%", "下载中 · %lld%"),
 "Explain the %@": ("%@ 설명", "%@の説明", "解释%@"),
 "Exported from Quenderin (on-device)": ("Quenderin에서 내보냄 (기기 내 처리)", "Quenderinからエクスポート（オンデバイス）", "从 Quenderin 导出（设备端）"),
 "Fast": ("빠름", "高速", "快速"),
 "Files": ("파일", "ファイル", "文件"),
 "Finish setting up Quenderin in the main window first.":
   ("먼저 기본 창에서 Quenderin 설정을 완료하세요.", "まずメインウィンドウでQuenderinのセットアップを完了してください。", "请先在主窗口完成 Quenderin 的设置。"),
 "Gated": ("승인 필요", "承認制", "需授权"),
 "Gated model — accept its license on Hugging Face first. Quenderin never asks for your HF token.":
   ("승인이 필요한 모델 — 먼저 Hugging Face에서 라이선스에 동의하세요. Quenderin은 HF 토큰을 절대 요구하지 않습니다.",
    "承認制モデル — まずHugging Faceでライセンスに同意してください。QuenderinがHFトークンを求めることはありません。",
    "受限模型——请先在 Hugging Face 接受其许可。Quenderin 绝不会索要你的 HF 令牌。"),
 "Generating a reply": ("답변 생성 중", "返信を生成中", "正在生成回复"),
 "Get": ("받기", "入手", "获取"),
 "Get %@": ("%@ 받기", "%@を入手", "获取 %@"),
 "Give the agent a goal": ("에이전트에게 목표 주기", "エージェントに目標を与える", "给智能体一个目标"),
 "Grant a workspace folder": ("작업 폴더 허용", "ワークスペースフォルダを許可", "授权工作区文件夹"),
 "Grant a workspace folder the agent may organize (with your approval per change)":
   ("에이전트가 정리할 수 있는 작업 폴더를 허용하세요 (변경마다 당신의 승인 필요)",
    "エージェントが整理できるワークスペースフォルダを許可します（変更ごとにあなたの承認が必要）",
    "授权一个智能体可整理的工作区文件夹（每次更改都需你批准）"),
}

path = os.path.join(os.path.dirname(__file__), "translations.tsv")
lines = open(path, encoding="utf-8").read().split("\n")
out, hit = [], 0
for ln in lines:
    if ln.startswith("#") or not ln.strip():
        out.append(ln); continue
    cols = ln.split("\t")
    if len(cols) == 5 and cols[0] in T and (not cols[2] or not cols[3] or not cols[4]):
        ko, ja, zh = T[cols[0]]
        cols[2], cols[3], cols[4] = ko, ja, zh
        hit += 1
    out.append("\t".join(cols))
open(path, "w", encoding="utf-8").write("\n".join(out))
missed = [k for k in T if k not in {l.split("\t")[0] for l in lines if l and not l.startswith("#")}]
print(f"chunk1: filled {hit} rows; {len(missed)} dict keys had no TSV row")
for k in missed: print("  MISS:", k[:80])
