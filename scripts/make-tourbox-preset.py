"""Writes extras/tourbox/FrameScrub.tb, the TourBox Lite preset for the classic key layout (the default), with the
TourBox in the right hand, from FrameScrub-2026-10-07.tb (the first preset, exported from TourBox Console) as the
template: its header and layout are kept, every control record is rewritten.

TourBox Console's <configBytes>: a 22-byte header, then 256 records of 13 bytes, one per control or combination:
  [record][kind][0][modifier][special][0][0][key]  (+ [modifier][special][0][0][key] for the second turning direction)
kind 0x00 = button, 0x08 = knob/scroll, 0x0a = knob/scroll turning slowly; modifier bits Ctrl 0x01, Shift 0x02,
Option 0x04, Cmd 0x08 (Ctrl from TourBox's Firefox preset: Ctrl+Tab / Ctrl+Shift+Tab on the knob); key = upper-case
ASCII, or with special = 1: 0x01 Up, 0x02 Down, 0x03 Left, 0x04 Right, 0x11 F8.
Record numbers, from the preset's <presetConf> layout and TourBox Console's key table (tourBoxKeys in its UI code):
0 Tall, 2 Top, 3 Short; 4 Knob, 5–7 Knob + Tall, Short, Top; 9 Scroll, 10 Scroll click, 11–13 Scroll + Tall, Short,
Top; 24 Tall double, 25 Top+Tall, 26 Tall+Short, 28 Short double, 29 Top+Short, 31 Top double; 34 C1, 35 C2,
42 Tour, 166 C1 double.

The TourBox Lite (productKey 401) has the Knob, the Scroll with its click, Tall, Short, Top, Tour, C1 and C2.
A button held for a combination also sends its own action, so the buttons are split: Tall, Short and Top are
modifiers (combinations and double presses only, nothing on a single press); Scroll click, Tour, C1 and C2 act on
a press and are never held for a combination.
"""
import base64, gzip, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent.parent / "extras" / "tourbox"
CTRL, SHIFT, OPTION, CMD = 0x01, 0x02, 0x04, 0x08
UP, DOWN, LEFT, RIGHT, F8 = (("special", c) for c in (0x01, 0x02, 0x03, 0x04, 0x11))


def key(k, mod=0):
    """(modifier, special, code) for a character or a special key."""
    if isinstance(k, tuple):
        return (mod, 1, k[1])
    return (mod, 0, ord(k.upper()) if k.isalpha() else ord(k))


def button(record, k, mod=0):
    m, s, c = key(k, mod)
    return bytes([record, 0x00, 0, m, s, 0, 0, c, 0, 0, 0, 0, 0])


def turn(record, back, forward, slow=False):
    (m1, s1, c1), (m2, s2, c2) = back, forward
    return bytes([record, 0x0A if slow else 0x08, 0, m1, s1, 0, 0, c1, m2, s2, 0, 0, c2])


# record: (bytes, [(key tuple, description), ...]) — descriptions in Russian, as the user's Console shows them.
PROFILE = {
    # Knob and Scroll, alone and with a modifier held
    4: (turn(4, key(","), key(".")), [(key(","), "Кадр назад"), (key("."), "Кадр вперёд")]),
    5: (turn(5, key(LEFT, SHIFT), key(RIGHT, SHIFT)), [(key(LEFT, SHIFT), "−1 с точно"), (key(RIGHT, SHIFT), "+1 с точно")]),
    6: (turn(6, key("["), key("]")), [(key("["), "Медленнее"), (key("]"), "Быстрее")]),
    7: (turn(7, key(",", SHIFT), key(".", SHIFT), slow=True), [(key(",", SHIFT), "Пред. видео"), (key(".", SHIFT), "След. видео")]),
    9: (turn(9, key(LEFT), key(RIGHT)), [(key(LEFT), "−5 с"), (key(RIGHT), "+5 с")]),
    11: (turn(11, key(DOWN), key(UP)), [(key(DOWN), "−60 с"), (key(UP), "+60 с")]),
    12: (turn(12, key("9"), key("0")), [(key("9"), "Громкость −"), (key("0"), "Громкость +")]),
    13: (turn(13, key("j", CTRL), key("l", CTRL), slow=True), [(key("j", CTRL), "Шаттл назад"), (key("l", CTRL), "Шаттл вперёд")]),
    # Action buttons: a single press
    10: (button(10, " "), [(key(" "), "Пауза / пуск")]),
    42: (button(42, "s"), [(key("s"), "Сохранить кадр")]),
    34: (button(34, "l"), [(key("l"), "Точка A-B")]),
    166: (button(166, "c", CMD), [(key("c", CMD), "Кадр в буфер")]),
    35: (button(35, "\b", SHIFT), [(key("\b", SHIFT), "Назад к месту до перемотки")]),
    # Modifiers: double presses and pairs only
    24: (button(24, "s", SHIFT), [(key("s", SHIFT), "Экспорт A-B")]),
    28: (button(28, "\b"), [(key("\b"), "Скорость 1×")]),
    31: (button(31, "f"), [(key("f"), "Полный экран")]),
    26: (button(26, "o", SHIFT | CMD), [(key("o", SHIFT | CMD), "Папка кадров")]),
    25: (button(25, "u"), [(key("u"), "SR-апскейл вкл/выкл")]),
    29: (button(29, "i"), [(key("i"), "Статистика")]),
}


def main():
    text = gzip.decompress((ROOT / "FrameScrub-2026-10-07.tb").read_bytes()).decode()
    config = bytearray(base64.b64decode(re.search(r"<configBytes>(.*?)</configBytes>", text, re.S).group(1)))
    assert len(config) == 22 + 256 * 13
    for record in range(256):   # every action of the template goes; a record keeps only its number and kind
        config[22 + 13 * record + 2:22 + 13 * (record + 1)] = bytes(11)
    for record, (data, _) in PROFILE.items():
        config[22 + 13 * record:22 + 13 * (record + 1)] = data
    shortcuts = []
    for _, names in PROFILE.values():
        for (m, s, c), d in names:
            code = 16777216 + c if s else c
            shortcuts.append(f"    <ShortDesc>\n      <m>{m}</m>\n      <s>{code}</s>\n      <d>{d}</d>\n    </ShortDesc>")
    text = re.sub(r"<configBytes>.*?</configBytes>", "<configBytes>" + base64.b64encode(config).decode() + "</configBytes>", text, flags=re.S)
    text = re.sub(r"<shortCuts>.*?</shortCuts>", "<shortCuts>\n" + "\n".join(shortcuts) + "\n  </shortCuts>", text, flags=re.S)
    text = re.sub(r"<presetName>.*?</presetName>", "<presetName>FrameScrub</presetName>", text)
    (ROOT / "FrameScrub.tb").write_bytes(gzip.compress(text.encode(), compresslevel=9))


if __name__ == "__main__":
    main()
