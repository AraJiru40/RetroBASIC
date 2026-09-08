#!/usr/bin/env python3
"""Build the Japanese RetroBASIC manual PDF from USER_MANUAL.md."""

from __future__ import annotations

import html
import re
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
    XPreformatted,
)

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "USER_MANUAL.md"
OUTPUT = ROOT / "output/pdf/RetroBASIC_User_Manual.pdf"

FONT = "ArialUnicode"
pdfmetrics.registerFont(TTFont(FONT, "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"))


def inline(text: str) -> str:
    text = html.escape(text.strip())
    def link(match):
        label, target = match.group(1), match.group(2)
        if target.startswith(("https://", "http://")):
            return f'<a href="{target}" color="#1e5aa8">{label}</a>'
        return label
    text = re.sub(r"\[([^]]+)\]\(([^)]+)\)", link, text)
    text = re.sub(r"`([^`]+)`", rf'<font name="{FONT}" color="#8b2346">\1</font>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def make_styles():
    base = getSampleStyleSheet()
    return {
        "body": ParagraphStyle(
            "JPBody", parent=base["BodyText"], fontName=FONT, fontSize=9.2,
            leading=14, spaceAfter=5, wordWrap="CJK", textColor=colors.HexColor("#20242a")
        ),
        "title": ParagraphStyle(
            "JPTitle", parent=base["Title"], fontName=FONT, fontSize=24,
            leading=31, alignment=TA_CENTER, textColor=colors.HexColor("#183153"),
            spaceAfter=15, wordWrap="CJK"
        ),
        "h2": ParagraphStyle(
            "JPH2", parent=base["Heading2"], fontName=FONT, fontSize=15,
            leading=20, spaceBefore=13, spaceAfter=7, keepWithNext=True,
            textColor=colors.HexColor("#183153"), wordWrap="CJK"
        ),
        "h3": ParagraphStyle(
            "JPH3", parent=base["Heading3"], fontName=FONT, fontSize=11.5,
            leading=16, spaceBefore=9, spaceAfter=5, keepWithNext=True,
            textColor=colors.HexColor("#28527a"), wordWrap="CJK"
        ),
        "bullet": ParagraphStyle(
            "JPBullet", parent=base["BodyText"], fontName=FONT, fontSize=9.2,
            leading=14, leftIndent=12, firstLineIndent=-8, spaceAfter=3, wordWrap="CJK"
        ),
        "code": ParagraphStyle(
            "JPCode", parent=base["Code"], fontName=FONT, fontSize=7.5,
            leading=10.5, leftIndent=7, rightIndent=7, spaceBefore=4, spaceAfter=7,
            borderColor=colors.HexColor("#cbd5df"), borderWidth=0.5,
            borderPadding=6, backColor=colors.HexColor("#f4f6f8"), wordWrap="CJK"
        ),
        "cell": ParagraphStyle(
            "JPCell", parent=base["BodyText"], fontName=FONT, fontSize=7.6,
            leading=10.5, wordWrap="CJK"
        ),
    }


def table_widths(columns: int, width: float):
    ratios = {
        2: [0.28, 0.72],
        3: [0.24, 0.32, 0.44],
        4: [0.17, 0.25, 0.28, 0.30],
    }.get(columns, [1 / columns] * columns)
    return [width * ratio for ratio in ratios]


def build_story(source: str, styles: dict, usable_width: float):
    lines = source.splitlines()
    story = []
    paragraph = []
    index = 0
    in_code = False
    code_lines = []

    def flush_paragraph():
        if paragraph:
            story.append(Paragraph(inline(" ".join(part.strip() for part in paragraph)), styles["body"]))
            paragraph.clear()

    while index < len(lines):
        line = lines[index]
        if line.startswith("```"):
            flush_paragraph()
            if in_code:
                story.append(XPreformatted(html.escape("\n".join(code_lines)), styles["code"]))
                code_lines.clear()
            in_code = not in_code
            index += 1
            continue
        if in_code:
            code_lines.append(line)
            index += 1
            continue
        if not line.strip():
            flush_paragraph()
            index += 1
            continue
        if line.startswith("# "):
            flush_paragraph()
            story.append(Spacer(1, 45 * mm))
            story.append(Paragraph(inline(line[2:]), styles["title"]))
            story.append(Paragraph("Version 1.35 / PC-8801 style BASIC environment",
                                   ParagraphStyle("Subtitle", parent=styles["body"], alignment=TA_CENTER,
                                                  textColor=colors.HexColor("#52616f"))))
            story.append(PageBreak())
            index += 1
            continue
        if line.startswith("## "):
            flush_paragraph()
            story.append(Paragraph(inline(line[3:]), styles["h2"]))
            index += 1
            continue
        if line.startswith("### "):
            flush_paragraph()
            story.append(Paragraph(inline(line[4:]), styles["h3"]))
            index += 1
            continue
        if line.startswith("| "):
            flush_paragraph()
            rows = []
            while index < len(lines) and lines[index].startswith("|"):
                raw = [cell.strip() for cell in lines[index].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{3,}:?", cell) for cell in raw):
                    rows.append([Paragraph(inline(cell), styles["cell"]) for cell in raw])
                index += 1
            if rows:
                table = Table(rows, colWidths=table_widths(len(rows[0]), usable_width), repeatRows=1)
                table.setStyle(TableStyle([
                    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dce7f1")),
                    ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#183153")),
                    ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#aab7c4")),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 4),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                    ("TOPPADDING", (0, 0), (-1, -1), 3),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ]))
                story.extend([table, Spacer(1, 5)])
            continue
        bullet = re.match(r"^\s*-\s+(.*)$", line)
        numbered = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
        if bullet or numbered:
            flush_paragraph()
            marker = "•" if bullet else numbered.group(1) + "."
            content = bullet.group(1) if bullet else numbered.group(2)
            story.append(Paragraph(f"{marker} {inline(content)}", styles["bullet"]))
            index += 1
            continue
        if line == "---":
            flush_paragraph()
            story.append(Spacer(1, 5))
            index += 1
            continue
        paragraph.append(line)
        index += 1

    flush_paragraph()
    return story


def page(canvas, document):
    canvas.saveState()
    canvas.setFont(FONT, 7.5)
    canvas.setFillColor(colors.HexColor("#687684"))
    canvas.drawString(18 * mm, 10 * mm, "RetroBASIC User Manual")
    canvas.drawRightString(A4[0] - 18 * mm, 10 * mm, str(document.page))
    canvas.restoreState()


def main():
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    document = SimpleDocTemplate(
        str(OUTPUT), pagesize=A4, title="RetroBASIC ユーザーズマニュアル",
        author="RetroBASIC", subject="RetroBASIC Version 1.35 User Manual",
        leftMargin=18 * mm, rightMargin=18 * mm, topMargin=16 * mm, bottomMargin=17 * mm,
    )
    styles = make_styles()
    story = build_story(SOURCE.read_text(encoding="utf-8"), styles,
                        A4[0] - document.leftMargin - document.rightMargin)
    document.build(story, onFirstPage=page, onLaterPages=page)
    print(OUTPUT)


if __name__ == "__main__":
    main()
