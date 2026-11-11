import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# ruleid: jelto-contracts-from-env-only
SIBLING = ROOT / "../contracts"
# ruleid: jelto-contracts-from-env-only
JOINED = ROOT.parent / ".." / "contracts"
# ruleid: jelto-contracts-from-env-only
NESTED = os.path.join(ROOT, "..", "jelto-contracts")

# ok: jelto-contracts-from-env-only
FROM_ENV = Path(os.environ["JELTO_CONTRACTS_DIR"])
# ok: jelto-contracts-from-env-only
LOCAL = ROOT / ".contracts"
