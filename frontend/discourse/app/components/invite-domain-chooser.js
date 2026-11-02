import ComboBoxComponent from "discourse/select-kit/components/combo-box";

// ComboBox's default search() (select-kit.js) is a plain substring filter
// that keeps matches in the content's original (alphabetical) order -- so
// typing e.g. "iitb.ac.in" against a list that also contains "ac.in" and
// every other *.ac.in domain surfaces whichever matching domain sorts first
// alphabetically, not the one that was actually typed. Rank matches instead:
// exact match first, then prefix match, then any other substring match,
// preserving the existing order within each rank.
export default class InviteDomainChooser extends ComboBoxComponent {
  search(filter) {
    const content = super.search(filter);
    if (!filter) {
      return content;
    }

    const normalizedFilter = this._normalize(filter);
    return [...content].sort(
      (a, b) =>
        this._matchRank(a, normalizedFilter) -
        this._matchRank(b, normalizedFilter)
    );
  }

  _matchRank(item, normalizedFilter) {
    const name = this._normalize(this.getName(item));
    if (name === normalizedFilter) {
      return 0;
    }
    if (name.startsWith(normalizedFilter)) {
      return 1;
    }
    return 2;
  }
}
