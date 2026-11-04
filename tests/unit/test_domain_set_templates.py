"""The ifupdown2 overlay ships every template domain-set renders.

domain-set copies /etc/*.tpl onto the rendered files with ``set -euo pipefail``
active on the first boot: any template referenced by the script and missing
from the overlay tree crashes the boot. This test extracts each ``cp … .tpl``
reference from the overlay script and demands the matching overlay file.
"""

import re
from pathlib import Path

OVERLAY = (
    Path(__file__).resolve().parents[2] / 'workflows' / 'bootc-debs-builder' /
    'ifupdown2'
)


def test_every_domain_set_template_is_shipped() -> None:
    """Each .tpl referenced by domain-set exists in the overlay etc/ tree."""
    script = (OVERLAY / 'usr' / 'sbin' / 'domain-set').read_text()
    templates = sorted(set(re.findall(r'/etc/([a-z]+\.tpl)', script)))
    assert templates, 'domain-set must reference at least one template'
    for name in templates:
        path = OVERLAY / 'etc' / name
        assert path.is_file(), f'missing overlay template etc/{name}'
        assert path.read_text().strip(), f'empty overlay template etc/{name}'


def test_hosts_tpl_keeps_the_bootstrap_entry() -> None:
    """hosts.tpl keeps the pmxcfs bootstrap entry form placeholders."""
    content = (OVERLAY / 'etc' / 'hosts.tpl').read_text()
    assert '# PVE' in content
    assert '{{ HOST }}' in content and '{{ FQDN }}' in content and '{{ IP }}' in content
