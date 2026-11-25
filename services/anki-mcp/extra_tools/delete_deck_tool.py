"""Delete deck tool - remove a normal Anki deck, cascading to its subdecks.

Ajout local (non amont) : l'addon AnkiMCP n'expose aucun delete_deck, alors que
les restructurations de decks laissent des coquilles vides non supprimables
depuis l'API. Ce fichier est injecte dans primitives/essential/tools/ par le
module NixOS (auto-decouverte par pkgutil, aucun autre patch necessaire).
"""
from typing import Annotated, Any

from pydantic import Field

from ....tool_decorator import Tool
from ....handler_wrappers import HandlerError, get_col


@Tool(
    "delete_deck",
    'Delete a normal (non-filtered) deck by name, cascading to ALL its subdecks. '
    'An empty deck tree is deleted as-is. If the tree still holds cards, the call '
    'fails unless confirmDeletion=true (the cards, and notes that belong only to '
    'them, are then deleted too - Anki\'s standard cascade). Use dry_run=true to '
    'preview. The Default deck (id 1) and filtered decks are always refused; use '
    'filtered_deck_delete for filtered decks. '
    'Returns deletedDecks (per-deck card counts), totalCards, message.',
    title="Delete Deck",
    write=True,
    idempotent_hint=True,
)
def delete_deck(
    deck: Annotated[
        str,
        Field(description='Deck name ("Parent::Child" form); subdecks go with it'),
    ],
    confirmDeletion: Annotated[
        bool,
        Field(description="Must be true to delete a deck tree that still contains cards"),
    ] = False,
    dry_run: Annotated[
        bool,
        Field(description="Preview what would be deleted without removing anything"),
    ] = False,
) -> dict[str, Any]:
    col = get_col()

    name = deck.strip()
    if not name or any(part.strip() == "" for part in name.split("::")):
        raise HandlerError(
            "Invalid deck name",
            hint="Use 'Deck' or 'Parent::Child', no empty parts",
            code="validation_error",
        )

    target = col.decks.by_name(name)
    if target is None:
        raise HandlerError(
            f'Deck "{name}" not found',
            hint="Deck names must match exactly (case-insensitive); list decks first",
            code="not_found",
        )

    did = target["id"]
    if did == 1:
        raise HandlerError(
            "The Default deck (id 1) cannot be deleted, even renamed",
            hint="Leave it empty or rename it back to 'Default'",
            code="validation_error",
        )
    if col.decks.is_filtered(did):
        raise HandlerError(
            f'Deck "{name}" is a filtered deck',
            hint="Use filtered_deck_delete for filtered decks",
            code="validation_error",
        )

    subtree = [(name, did)] + list(col.decks.children(did))
    counts = {
        child_name: col.decks.card_count(child_id, include_subdecks=False)
        for child_name, child_id in subtree
    }
    total_cards = sum(counts.values())

    if total_cards and not dry_run and not confirmDeletion:
        raise HandlerError(
            f'Deck tree "{name}" contains {total_cards} card(s); deletion refused',
            hint="Pass confirmDeletion=true to delete the cards too, "
                 "or dry_run=true to preview",
            code="validation_error",
            cardsByDeck=counts,
        )

    if dry_run:
        return {
            "dryRun": True,
            "deletedDecks": counts,
            "totalCards": total_cards,
            "message": f"Would delete {len(subtree)} deck(s) holding {total_cards} card(s)",
        }

    col.decks.remove([child_id for _, child_id in subtree])
    return {
        "dryRun": False,
        "deletedDecks": counts,
        "totalCards": total_cards,
        "message": f"Deleted {len(subtree)} deck(s), {total_cards} card(s)",
    }
