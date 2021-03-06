<!-- THIS IS AUTOGENERATED FILE. DO NOT CHANGE IT MANUALLY! -->

# Cardano SL

[![Build Status](https://travis-ci.org/input-output-hk/cardano-sl.svg)](https://travis-ci.org/input-output-hk/cardano-sl)
[![Windows build status](https://ci.appveyor.com/api/projects/status/github/input-output-hk/cardano-sl?branch=master&svg=true)](https://ci.appveyor.com/project/jagajaga/cardano-sl)
[![Release](https://img.shields.io/github/release/input-output-hk/cardano-sl.svg)](https://github.com/input-output-hk/cardano-sl/releases)

<!-- CARDANO_SL_README_BEGIN_1 -->
## What is Cardano SL?

Cardano SL (or Cardano Settlement Layer) is a cryptographic currency designed
and developed by [IOHK](https://iohk.io/team) in conjunction with the University
of Edinburgh, the University of Athens and the University of Connecticut. Cardano
SL is based on the Haskell implementation of the white paper
["Ouroboros: A Provably Secure Proof-of-Stake Blockchain Protocol"](https://iohk.io/research/papers/#9BKRHCSI)
by Aggelos Kiayias, Alexander Russell, Bernardo David and Roman Oliynykov.

You can think of Cardano SL as Bitcoin reimagined with a freedom to fix Bitcoin’s
design flaws. Please read ["What Makes Cardano SL Special?"](https://cardanodocs.com/introduction/#what-makes-cardano-sl-special)
for more info about similarities and differences between Cardano SL and Bitcoin.
<!-- CARDANO_SL_README_END_1 -->
<!-- CARDANO_SL_README_BEGIN_2 -->
## Beyond Settlement Layer

Cardano SL is called a "Layer" for a reason. It is the first component of
the Cardano Platform. Eventually, it will be expanded with a Control Layer,
serving as a trusted computation framework to evaluate a special
kind of proofs to ensure that a certain computation was carried out
correctly. In gaming and gambling, such systems are used for
verifying honesty of random number generation and game
outcomes. Accompanied with side chains, it will make possible to accomplish
such tasks as provably fair distribution of winnings in games. The
application of Control Layer lies well beyond gaming and gambling. Identity
management, credit system and more will be a part of Cardano Platform.
We are also aiming to evolve Daedalus, the Cardano SL [wallet application](https://github.com/input-output-hk/daedalus),
into a universal cryptocurrency wallet featuring automated
cryptocurrency trading and cryptocurrency-to-fiat transactions.
<!-- CARDANO_SL_README_END_2 -->
<!-- CARDANO_SL_README_BEGIN_3 -->
## Supported Platforms

Supported platforms are Windows, macOS and Linux. There are
[installers for Windows and macOS](https://daedaluswallet.io/#download),
which include a main node and [Daedalus wallet](https://github.com/input-output-hk/daedalus).

Linux installer is going to be released soon. For now, to
get Cardano SL on Linux, please refer to the [Bulding Cardano SL and Daedalus from
Source](https://cardanodocs.com/for-contributors/building-from-source) chapter.
<!-- CARDANO_SL_README_END_3 -->
<!-- CARDANO_SL_README_BEGIN_4 -->
## Cardano SL and Daedalus Bridge

Cardano SL consists of a collection of binaries that constitute
the backend, a PureScript API for the Electron-based wallet, and the
Electron-based wallet called “Daedalus”.

The source code for both Cardano SL and Daedalus Bridge can be obtained
from the [official repository](https://github.com/input-output-hk/cardano-sl).

For instructions on building Cardano, please see the [building from source](https://cardanodocs.com/for-contributors/building-from-source/) section.

<!-- CARDANO_SL_README_END_4 -->
<!-- CARDANO_SL_README_BEGIN_5 -->
## For Contributors

Thank you for considering to help out with the source code! We welcome contributions from anyone, and are grateful for even the smallest of fixes!

If you'd like to contribute to Cardano SL, please fork this repository, fix, commit and send a pull request for the maintainers to review and merge into the main code base.

Please make sure your contributions adhere to our coding guidelines:

* Code must adhere to the [Serokell Haskell Style Guide](https://github.com/serokell/serokell-util/blob/master/serokell-style.md).
* Code must be documented with [Haddock](https://www.haskell.org/haddock/doc/html/index.html).
* Pull requests need to be based on and opened against the `master` branch.

Please note that this project uses a custom prelude [Universum](https://github.com/serokell/universum) instead of the default one.

## License

Cardano SL is released under the terms of the [MIT license](https://opensource.org/licenses/MIT). Please see [LICENSE](https://github.com/input-output-hk/cardano-sl/blob/master/LICENSE) for more information.
<!-- CARDANO_SL_README_END_5 -->
