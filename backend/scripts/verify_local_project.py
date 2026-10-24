#!/usr/bin/env python3
"""Verificação *local* opcional de um projeto recebido da Oficina.

Exemplo: python backend/scripts/verify_local_project.py C:/projetos/meu_app --flutter
ATENÇÃO: --flutter e --run-tests invocam comandos do projeto. Execute-os apenas
em uma máquina/contêiner isolado e em código que você confia. Nunca na API do Railway.
"""
from __future__ import annotations

import argparse
import ast
import json
import shutil
import subprocess
import sys
from pathlib import Path


def python_syntax(root: Path) -> dict:
    errors = []
    checked = 0
    for path in root.rglob('*.py'):
        if any(part in {'.git', '.venv', 'venv', 'node_modules', 'build', '__pycache__'} for part in path.relative_to(root).parts):
            continue
        try:
            if path.stat().st_size > 2 * 1024 * 1024:
                continue
            ast.parse(path.read_text('utf-8-sig'), filename=str(path))
            checked += 1
        except (SyntaxError, UnicodeError, OSError, ValueError) as exc:
            errors.append({'path': str(path.relative_to(root)), 'message': str(exc)[:500]})
    return {'ok': not errors, 'checked_files': checked, 'issues': errors[:100]}


def run_command(root: Path, command: list[str], timeout: int) -> dict:
    if shutil.which(command[0]) is None:
        return {'command': command, 'ok': False, 'error': f'Ferramenta não encontrada: {command[0]}'}
    try:
        completed = subprocess.run(command, cwd=str(root), capture_output=True, text=True,
                                   timeout=timeout, check=False)
        return {
            'command': command,
            'ok': completed.returncode == 0,
            'exit_code': completed.returncode,
            'output_tail': (completed.stdout + '\n' + completed.stderr)[-12000:],
        }
    except subprocess.TimeoutExpired:
        return {'command': command, 'ok': False, 'error': f'Limite de {timeout}s excedido'}
    except OSError as exc:
        return {'command': command, 'ok': False, 'error': str(exc)}


def main() -> int:
    parser = argparse.ArgumentParser(description='Verificador local de ZIPs/projetos da Oficina Gamma')
    parser.add_argument('project', type=Path, help='Pasta do projeto já extraído')
    parser.add_argument('--flutter', action='store_true', help='Executa flutter analyze localmente; pode executar ferramentas do projeto')
    parser.add_argument('--run-tests', action='store_true', help='Executa flutter test (requer --flutter); pode executar código do projeto')
    parser.add_argument('--timeout', type=int, default=180, help='Tempo máximo por comando (10-900s)')
    parser.add_argument('--json-output', type=Path, help='Salvar relatório JSON fora do projeto')
    args = parser.parse_args()
    root = args.project.resolve()
    if not root.is_dir():
        parser.error('A pasta do projeto não existe')
    if args.run_tests and not args.flutter:
        parser.error('--run-tests exige --flutter')
    timeout = max(10, min(900, args.timeout))
    results = {'project': str(root), 'python_syntax': python_syntax(root),
               'flutter': [], 'notes': [
                   'Verificação local; a API da Gamma não executa código recebido.',
                   'O analisador Flutter só roda se --flutter for informado e o Flutter SDK estiver instalado.',
               ]}
    if args.flutter:
        results['flutter'].append(run_command(root, ['flutter', 'analyze', '--no-pub'], timeout))
        if args.run_tests:
            results['flutter'].append(run_command(root, ['flutter', 'test', '--no-pub'], timeout))
    results['ok'] = results['python_syntax']['ok'] and all(x['ok'] for x in results['flutter'])
    payload = json.dumps(results, ensure_ascii=False, indent=2)
    print(payload)
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(payload + '\n', encoding='utf-8')
    return 0 if results['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
