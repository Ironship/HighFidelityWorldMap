import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "update_curseforge_description.py"


def load_module():
    spec = importlib.util.spec_from_file_location("update_curseforge_description", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def test_build_logo_upload_request_uses_multipart_upload():
    module = load_module()

    request = module.build_logo_upload_request(
        "https://api.curseforge.com/v1/mods/123/logo",
        b"fake-png-bytes",
        "logo.png",
        "token-value",
    )

    assert request.get_method() == "POST"
    assert request.headers.get("Content-type", "").startswith("multipart/form-data; boundary=")
    body = request.data
    assert b'name="file"' in body
    assert b'filename="logo.png"' in body
    assert b"fake-png-bytes" in body
