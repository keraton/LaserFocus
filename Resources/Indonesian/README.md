# Indonesian word list

`words-id.txt` lists every word form of the Indonesian Hunspell dictionary (hunspell-id,
by Benitius Brevoort and the hunspell-id authors), as distributed with LibreOffice:
https://github.com/LibreOffice/dictionaries/tree/master/id

It is released under the GNU Lesser General Public License version 3; see
`LICENSE-LGPL-3.0.txt`. The list ships as a separate, replaceable file inside the app.

Rebuild it with:

    scripts/expand-hunspell.py id_ID.dic id_ID.aff > Resources/Indonesian/words-id.txt
