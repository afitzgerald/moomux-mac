# Third-party notices

Moomux includes the following third-party software, each under the MIT License
reproduced at the end of this file.

| Component | Used for | Copyright |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty) | Terminal engine, statically linked | Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors |
| [libghostty-spm](https://github.com/Lakr233/libghostty-spm) | Swift layer over libghostty | Copyright (c) 2026 @Lakr233 |
| [MSDisplayLink](https://github.com/Lakr233/MSDisplayLink) | Display link, via libghostty-spm | Copyright (c) 2024 Lakr Aream |
| [DiffKit](https://github.com/afitzgerald/DiffKit) | Diff rendering on the iPhone | Copyright (c) 2026 Alan Fitzgerald |
| [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) | The terminal themes in `Resources/ghostty-themes` | Copyright (c) 2011 to Present Mark Badolato |

The iTerm2-Color-Schemes license covers the collection. Its own notice adds:
"The copyright/license for each individual theme belongs to the author of that
theme."

## Inside the libghostty binary

The prebuilt libghostty that libghostty-spm downloads statically links these
too. Where a library offers a choice of license, the one Moomux takes is named.

| Component | License | Copyright |
|---|---|---|
| [Oniguruma](https://github.com/kkos/oniguruma) | BSD-2-Clause (below) | Copyright (c) 2002-2021 K.Kosako |
| [Highway](https://github.com/google/highway) | BSD-3-Clause, of Apache-2.0 or BSD-3-Clause (below) | Copyright (c) The Highway Project Authors |
| [simdutf](https://github.com/simdutf/simdutf) | MIT, of Apache-2.0 or MIT | Copyright 2021 The simdutf authors |
| [Wuffs](https://github.com/google/wuffs) | MIT, of Apache-2.0 or MIT | Copyright 2023 The Wuffs Authors |
| [zlib](https://zlib.net) | zlib License | (C) 1995-2026 Jean-loup Gailly and Mark Adler |
| [libpng](https://github.com/pnggroup/libpng) | PNG Reference Library License v2 | Copyright (c) 1995-2026 The PNG Reference Library Authors |
| [GNU gettext](https://www.gnu.org/software/gettext/) (libintl) | [LGPL-2.1-or-later](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) | Free Software Foundation, Inc. |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (embedded font) | [SIL OFL 1.1](https://openfontlicense.org) | Copyright 2020 The JetBrains Mono Project Authors |
| [Symbols Nerd Font](https://github.com/ryanoasis/nerd-fonts) (embedded font) | [SIL OFL 1.1](https://openfontlicense.org), glyphs per its [license audit](https://github.com/ryanoasis/nerd-fonts/blob/-/license-audit.md) | Copyright (c) 2016, Ryan McIntyre |

libintl's source is available from the GNU gettext project above. libghostty's
source, the work it is linked into, is at https://github.com/ghostty-org/ghostty.

The app's GhosttyKit resource bundle also carries
[bash-preexec](https://github.com/rcaloras/bash-preexec) (MIT), with its
license file beside it.

### BSD-2-Clause (Oniguruma)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

### BSD-3-Clause (Highway)

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1.  Redistributions of source code must retain the above copyright notice, this
    list of conditions and the following disclaimer.

2.  Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

3.  Neither the name of the copyright holder nor the names of its
    contributors may be used to endorse or promote products derived from
    this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## MIT License

Covers every component above listed as MIT.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
