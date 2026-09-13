# labwright_rsrc_parse

A clean-room reader for the LabVIEW™ software RSRC container (`.vi` / `.ctl` / `.llb`).
Info about the format can be viewed here: https://labviewwiki.org/wiki/Resource_Container.

This is a LabVIEW-specific RSRC parser. The container descends from the classic Mac resource
fork, but its header, descriptors and name table differ, and only the block types LabVIEW
writes are modelled; there is no guarantee that any other RSRC-tagged file reads.

Every block type LabVIEW writes is catalogued in `BlockTag`; each decoded one lives in
`lib/src/blocks/<TAG>_<name>.dart` as a view over the section bytes with its byte layout at
the top of the file. The end goal is a decoder for _every_ resource type.

## Trademarks

LabVIEW™ is a trademark of National Instruments. Neither Labwright, nor any software programs
or other goods or services offered by Labwright, are affiliated with, endorsed by, or sponsored
by National Instruments. This package is a clean-room reader for the RSRC container format and
is not an NI product.

## License
BSD-3-Clause
