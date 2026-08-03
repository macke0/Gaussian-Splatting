"""Identifieringen testas utan modell.

Ollama svarar olika varje gång och finns inte på byggmaskinen. Det som går att
hålla fast är formen på svaret: att en slarvig modell inte får ta ner servern,
och att RoomPlans gissning når fram till prompten.
"""

from __future__ import annotations

import json

import pytest

from spatialfit_server import identify


@pytest.fixture
def answers(monkeypatch):
    """Fångar det som skulle skickats till modellen och svarar i dess ställe."""
    sent = {}

    def reply(text):
        def _ask(payload):
            sent.update(payload)
            return text
        monkeypatch.setattr(identify, "_ask", _ask)
        return sent

    return reply


class TestSvaret:

    def test_ett_valformat_svar_blir_en_ordbok(self, answers):
        answers(json.dumps({"kind": "spis", "detail": "rostfri induktionshäll",
                            "confidence": 0.8}))

        result = identify.describe(b"jpeg")
        assert result == {"kind": "spis", "detail": "rostfri induktionshäll",
                          "confidence": 0.8}

    def test_skrapet_svar_ger_ett_fel_i_stallet_for_en_krasch(self, answers):
        answers("Det där ser ut som en spis!")

        with pytest.raises(identify.VisionError):
            identify.describe(b"jpeg")

    def test_en_lista_ar_inte_ett_svar(self, answers):
        answers(json.dumps(["spis"]))

        with pytest.raises(identify.VisionError):
            identify.describe(b"jpeg")

    def test_falt_som_saknas_blir_tomma_inte_None(self, answers):
        answers(json.dumps({"kind": "skåp"}))

        result = identify.describe(b"jpeg")
        assert result["detail"] == ""
        assert result["confidence"] == 0.0

    def test_en_confidence_som_ar_text_slas_till_noll(self, answers):
        """Modellen skriver ibland "hög" i stället för ett tal. Ett svar med
        okänd säkerhet ska behandlas som osäkert, inte som ett fel."""
        answers(json.dumps({"kind": "spis", "confidence": "hög"}))

        assert identify.describe(b"jpeg")["confidence"] == 0.0


class TestPrompten:

    def test_bilden_skickas_base64_kodad(self, answers):
        sent = answers(json.dumps({"kind": "spis"}))
        identify.describe(b"jpeg")

        assert sent["images"] == ["anBlZw=="]

    def test_roomplans_gissning_foljer_med(self, answers):
        sent = answers(json.dumps({"kind": "diskmaskin"}))
        identify.describe(b"jpeg", hint="skåp")

        assert "skåp" in sent["prompt"]

    def test_utan_gissning_namns_ingen(self, answers):
        sent = answers(json.dumps({"kind": "spis"}))
        identify.describe(b"jpeg")

        assert "Skanningen tror" not in sent["prompt"]
