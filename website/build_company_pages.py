"""Build the existing company site's VoiceType product, support, and privacy pages."""
from pathlib import Path
import html
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "website" / "voicetype"


def render_markdown(path: Path) -> str:
    source = path.read_text()
    source = re.sub(r"^Public URL:.*\n", "", source, flags=re.MULTILINE)
    result = subprocess.run(["pandoc", "--from=gfm", "--to=html5"], input=source,
                            text=True, check=True, capture_output=True).stdout
    return result.replace("<table>", '<div class="table-scroll" tabindex="0" role="region" aria-label="Data collection details"><table>').replace("</table>", "</table></div>")


def page(title: str, description: str, body: str, section: str = "") -> str:
    links = [("", "VoiceType"), ("support/", "Support"), ("privacy/", "Privacy")]
    nav = "".join(f'<a href="/voicetype/{path}"' + (' aria-current="page"' if section == path else '') + f'>{name}</a>' for path, name in links)
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} · Apeonwheels</title><meta name="description" content="{html.escape(description, quote=True)}">
<link rel="canonical" href="https://apeonwheels.com/voicetype/{section}"><link rel="stylesheet" href="/voicetype/site.css">
</head><body><a class="skip" href="#main">Skip to content</a>
<header><div class="wrap top"><a class="brand" href="/">Apeonwheels</a><nav aria-label="VoiceType navigation">{nav}</nav></div></header>
<main id="main" class="wrap">{body}</main>
<footer><div class="wrap">© 2026 Apeonwheels Inc. · <a href="mailto:kq@apeonwheels.com">kq@apeonwheels.com</a></div></footer></body></html>
'''


product = '''<h1>VoiceType</h1>
<p class="lede">Turn speech into text in the apps you use on iPhone and iPad.</p>
<p>VoiceType pairs a dictation keyboard with an app for microphone sessions, transcript history, and transcription credits. Sign in with Apple, enable the keyboard, and start speaking.</p>
<div class="grid"><section class="card"><h2>Dictate from your keyboard</h2><p>Start and finish a spoken clip from VoiceType's keyboard. The transcript is inserted into the current text field.</p></section>
<section class="card"><h2>Your words and languages</h2><p>Choose your languages and save names or phrases in a personal vocabulary to help recognize the words you use.</p></section>
<section class="card"><h2>Keep useful transcripts</h2><p>Review and copy earlier transcriptions in History. Failed recordings stay on your device so you can retry or delete them.</p></section>
<section class="card"><h2>Pay as you go</h2><p>Buy consumable transcription credit packs through the App Store. There is no recurring subscription or automatic refill.</p></section></div>
<h2>How it works</h2><ol><li>Add VoiceType in iOS keyboard settings and allow Full Access.</li><li>Sign in and turn on the keyboard microphone in VoiceType. When it is off, the keyboard's microphone shortcut opens the app to start the session.</li><li>Return to your writing app, speak a clip, and tap again to finish.</li></ol>
<p>Choose how long your microphone session lasts. You can return to VoiceType and turn it off at any time. Transcription requires a network connection and credit. Third-party keyboards are unavailable in some secure fields and apps.</p>
<section class="notice"><h2 style="margin-top:0">Your speech and your privacy</h2><p>VoiceType sends the clips you submit, selected languages, and vocabulary hints to our server and OpenAI for transcription. Idle session audio stays on your device. We do not sell your data, track you across apps, or include advertising SDKs.</p><p>Read the <a href="/voicetype/privacy/">Privacy Policy</a> for data collection, retention, and account deletion details.</p></section>
<h2>Need a hand?</h2><p>See the <a href="/voicetype/support/">setup guide and support</a>, or email <a href="mailto:kq@apeonwheels.com">kq@apeonwheels.com</a>.</p>
<section class="lang-note" lang="zh-Hans"><h2>语音变文字，随时输入</h2><p>VoiceType 是 iPhone 和 iPad 上的语音转文字键盘。开启麦克风会话后，返回需要输入的 App，在键盘中开始和结束一句话，转写结果会插入输入框。你可以设置会话时长、管理语言和常用词汇，并在历史记录中查看转写或重试失败的录音。</p><p>语音转写需要网络和余额，音频及词汇提示由 VoiceType 与 OpenAI 处理。购买使用 App Store 点数包，没有自动续费。查看<a href="/voicetype/support/#简体中文帮助">中文帮助</a>。</p></section>'''

SITE.mkdir(parents=True, exist_ok=True)
(SITE / "index.html").write_text(page("VoiceType", "VoiceType, a speech-to-text keyboard for iPhone and iPad by Apeonwheels Inc.", product))
for section, name, source in [("privacy", "Privacy Policy", "PRIVACY_POLICY.md"), ("support", "Support", "SUPPORT.md")]:
    folder = SITE / section
    folder.mkdir(exist_ok=True)
    (folder / "index.html").write_text(page(f"VoiceType {name}", f"{name} for VoiceType by Apeonwheels Inc.", render_markdown(ROOT / "docs" / source), section + "/"))
print("Built VoiceType product, privacy, and support pages.")
