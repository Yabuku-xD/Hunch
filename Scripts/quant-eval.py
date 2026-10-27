#!/usr/bin/env python3
"""Compare EmbeddingGemma 2 GGUF quantizations against a BF16 reference, with the app's own runtime.

usage: Scripts/quant-eval.py <reference-BF16.gguf> <candidate.gguf> [<candidate.gguf> ...]

Builds a fixed corpus (repo docs and sources cut into passages, plus multilingual lines), embeds it with
`hunch-bench --embed-eval` per model, and reports per candidate, at 768 and at 256 dimensions (the app's size):
  cos_mean / cos_min   cosine between the candidate's and the reference's vector for the same input
  top10                mean overlap of each query's top 10 documents with the reference's top 10
  top1                 share of queries whose best document matches the reference's
"""
import json
import math
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, ".build", "release", "hunch-bench")

QUERIES = [
    "dog photos", "tax return 2023", "beach holiday pictures", "quarterly budget spreadsheet",
    "meeting notes from last week", "resume pdf", "wedding photos", "lease agreement", "flight itinerary",
    "invoice from contractor", "birthday party video", "swift package manifest", "python data analysis",
    "screenshot of error", "podcast episode recording", "lecture slides", "thesis chapter draft",
    "insurance claim", "passport scan", "workout plan", "how the index catches up after a restart",
    "where the model file is downloaded", "keyboard shortcut to open the panel", "glass panel layout",
    "what happens when a file is deleted", "text inside images", "speech in videos", "memory use when idle",
    "license of the model", "uninstall the app", "facture du plombier", "Steuererklärung 2024", "receta de paella",
    "会議の議事録", "合同 租赁", "отчёт о продажах", "فاتورة الكهرباء", "contrato de aluguel", "fattura elettrica",
    "hotel booking confirmation", "car repair receipt", "medical test results", "school report card",
    "recipe for chocolate cake", "project roadmap", "bank statement march", "gym membership cancel",
    "photo of a receipt", "debounce the query", "vector search speed",
]
LINES = [
    ("Facture", "Facture n° 2291 pour la réparation de la fuite sous l'évier, total 184 euros."),
    ("Steuer", "Steuererklärung 2024: Belege für Fahrtkosten und Arbeitszimmer bis Juli einreichen."),
    ("Paella", "Receta de paella valenciana: arroz, pollo, conejo, judías verdes y azafrán."),
    ("会議", "第3四半期の会議の議事録。予算の見直しと新しい採用計画について話し合った。"),
    ("合同", "房屋租赁合同，租期一年，每月租金四千元，押金两个月。"),
    ("Отчёт", "Отчёт о продажах за второй квартал: рост выручки на двенадцать процентов."),
    ("فاتورة", "فاتورة الكهرباء لشهر مارس بقيمة مئتين وخمسين ريالا."),
    ("Contrato", "Contrato de aluguel do apartamento em Lisboa, com início em setembro."),
    ("Fattura", "Fattura elettrica di aprile, consumo 320 kWh, scadenza il 15 maggio."),
    ("Hotel", "Your booking at Hotel Aurora is confirmed for 12–15 June, two adults, breakfast included."),
    ("Garage", "Receipt: brake pads and rotors replaced, labour two hours, total 412.50."),
    ("Lab", "Blood test results: cholesterol within range, vitamin D slightly low."),
    ("Cake", "Chocolate cake: 200 g dark chocolate, 4 eggs, 150 g sugar, bake 35 minutes at 180 °C."),
    ("Bank", "Statement for March: opening balance, card payments, salary credit, closing balance."),
    ("Gym", "To cancel your gym membership, give 30 days' notice in writing at the front desk."),
]


def corpus():
    docs = [{"title": t, "text": x} for t, x in LINES]
    picks = []
    for base in ("README.md", "CHANGELOG.md", "CONTRIBUTING.md", "docs", "Sources/HunchCore", "Sources/Hunch"):
        p = os.path.join(ROOT, base)
        if os.path.isfile(p):
            picks.append(p)
        else:
            for d, _, fs in sorted(os.walk(p)):
                picks += [os.path.join(d, f) for f in sorted(fs) if f.endswith((".md", ".swift"))]
    for path in picks:
        text = open(path, encoding="utf-8", errors="ignore").read()
        name = os.path.basename(path)
        for i in range(0, min(len(text), 4800), 800):
            chunk = text[i:i + 800].strip()
            if len(chunk) > 200:
                docs.append({"title": name, "text": chunk})
        if len(docs) >= 400:
            break
    return {"queries": QUERIES, "docs": docs[:400]}


def embed(model, corpus_path):
    out = tempfile.mktemp(suffix=".json")
    subprocess.run([BENCH, "--embed-eval", model, corpus_path, out], check=True, stdout=subprocess.DEVNULL)
    return json.load(open(out))


def cut(v, n):
    v = v[:n]
    s = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / s for x in v]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def metrics(ref, cand, n):
    rq, rd = [cut(v, n) for v in ref["queries"]], [cut(v, n) for v in ref["docs"]]
    cq, cd = [cut(v, n) for v in cand["queries"]], [cut(v, n) for v in cand["docs"]]
    cos = [dot(a, b) for a, b in zip(rq + rd, cq + cd)]
    top10 = top1 = 0.0
    for a, b in zip(rq, cq):
        ra = sorted(range(len(rd)), key=lambda i: -dot(a, rd[i]))[:10]
        rb = sorted(range(len(cd)), key=lambda i: -dot(b, cd[i]))[:10]
        top10 += len(set(ra) & set(rb)) / 10
        top1 += ra[0] == rb[0]
    k = len(rq)
    return sum(cos) / len(cos), min(cos), top10 / k, top1 / k


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path = tempfile.mktemp(suffix=".json")
    data = corpus()
    json.dump(data, open(path, "w"))
    print(f"corpus: {len(data['queries'])} queries, {len(data['docs'])} documents")
    ref = embed(sys.argv[1], path)
    print(f"{'model':48} {'MB':>6} | 768: cos_mean cos_min top10 top1 | 256: cos_mean cos_min top10 top1")
    for m in sys.argv[2:]:
        try:
            c = embed(m, path)
        except subprocess.CalledProcessError:
            print(f"{os.path.basename(m):48} does not load in this llama.cpp build")
            continue
        a, b = metrics(ref, c, 768), metrics(ref, c, 256)
        mb = os.path.getsize(m) / 1e6
        print(f"{os.path.basename(m):48} {mb:6.1f} | {a[0]:.5f} {a[1]:.5f} {a[2]:.3f} {a[3]:.3f} | "
              f"{b[0]:.5f} {b[1]:.5f} {b[2]:.3f} {b[3]:.3f}")


if __name__ == "__main__":
    main()
