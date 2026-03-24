# Skills Cheat Sheet — Tax Collector

Quick reference for activating AI skill personas.

## Always-On Skills (load for every session)
| Skill | When |
|---|---|
| `skill_shared_infrastructure` | Any task touching servers, Docker, n8n, PostgreSQL |
| `skill_tax_collector_core` | Any task touching this project's DB, document logic, tax rules |

## Specialist Skills (activate as needed)
| Skill | When |
|---|---|
| `skill_python_data_engineer` | Building extractors, pipeline scripts, data transforms |

## How to Activate
Reference the skill name in conversation:
> "Acting as the Python Data Engineer with tax-collector-core context loaded..."

Or use `/use-skill` to browse and select.
