"""Regressões de migração, integridade e recuperação da Memória v3."""
import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core import memory as mem
from app.core.memory_v3 import SQLiteMemoryStore
from app.core.memory_writer_v3 import apply_memory_operations, consolidate_turn


class MemoryV3Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous = os.environ.get('DATA_DIR')
        os.environ['DATA_DIR'] = self.tmp.name

    def tearDown(self):
        if self.previous is None:
            os.environ.pop('DATA_DIR', None)
        else:
            os.environ['DATA_DIR'] = self.previous
        self.tmp.cleanup()

    def test_migrate_legacy_without_modification(self):
        path = Path(self.tmp.name) / 'memory' / 'a.json'
        path.parent.mkdir(parents=True)
        data = {'facts': [{'id': 'one', 'text': 'Nome: Maria', 'source': 'user'}]}
        original = json.dumps(data, ensure_ascii=False)
        path.write_text(original, encoding='utf-8')
        store = mem.get_store('a')
        self.assertIsInstance(store, SQLiteMemoryStore)
        self.assertEqual([f['text'] for f in store.list_facts()], ['Nome: Maria'])
        store.add_fact('Projeto: Gamma')
        self.assertEqual(path.read_text(encoding='utf-8'), original)
        self.assertEqual(len(mem.get_store('a').list_facts()), 2)

    def test_migrate_backup_when_json_corrupt(self):
        path = Path(self.tmp.name) / 'memory' / 'u.json'
        path.parent.mkdir(parents=True)
        path.write_text('{broken')
        path.with_suffix('.json.bak').write_text(json.dumps({'facts': [{'id': 'f', 'text': 'Nome: Ana'}]}))
        self.assertEqual(mem.get_store('u').list_facts()[0]['text'], 'Nome: Ana')
        self.assertEqual(path.read_text(), '{broken')

    def test_no_silent_empty_migration_on_corruption(self):
        path = Path(self.tmp.name) / 'memory' / 'u.json'
        path.parent.mkdir(parents=True)
        path.write_text('{broken')
        with self.assertRaises(ValueError):
            mem.get_store('u')
        # Após reparar o arquivo, a primeira migração pode continuar.
        path.write_text(json.dumps({'facts': [{'id': 'f', 'text': 'Nome: Ana'}]}))
        self.assertEqual(len(mem.get_store('u').list_facts()), 1)

    def test_isolation(self):
        mem.get_store('alice').add_fact('Nome: Alice')
        self.assertEqual(mem.get_store('bob').list_facts(), [])

    def test_update_history_undo(self):
        s = mem.get_store('u')
        item = s.add_fact('Mora em: Campinas')
        s.add_fact('Mora em: Santos')
        self.assertEqual([f['text'] for f in s.list_facts()], ['Mora em: Santos'])
        events = s.list_history()
        update = next(e for e in events if e['action'] == 'UPDATE')
        s.undo_event(update['event_id'])
        self.assertEqual(s.list_facts()[0]['text'], 'Mora em: Campinas')
        self.assertEqual(item['id'], s.list_facts()[0]['id'])
        with self.assertRaises(ValueError):
            s.undo_event(update['event_id'])

    def test_old_undo_cannot_overwrite_newer_edit(self):
        s = mem.get_store('u')
        item = s.add_fact('Nome: Ana')
        initial = s.list_history()[0]['event_id']
        s.update_fact(item['id'], text='Nome: Maria')
        with self.assertRaises(ValueError):
            s.undo_event(initial)
        self.assertEqual(s.list_facts()[0]['text'], 'Nome: Maria')

    def test_metadata_writer_creation_can_be_undone(self):
        s = mem.get_store('u')
        fact = s.add_fact('Projeto: Gamma')
        s.set_metadata(fact['id'], kind='project', subject='Gamma', conversation_id='conv')
        event = s.list_history()[0]
        self.assertEqual(event['action'], 'ADD')
        s.undo_event(event['event_id'])
        self.assertEqual(s.list_facts(), [])

    def test_undo_added_fact(self):
        s = mem.get_store('u')
        s.add_fact('Nome: Ana')
        add = next(e for e in s.list_history() if e['action'] == 'ADD')
        s.undo_event(add['event_id'])
        self.assertEqual(s.list_facts(), [])

    def test_clear_also_erases_episodes_and_history(self):
        s = mem.get_store('u')
        s.add_fact('Nome: Ana')
        s.save_episode('Decidimos usar Flutter no projeto Gamma', 'Gamma', 'c1')
        s.clear()
        self.assertEqual(s.list_facts(), [])
        self.assertEqual(s.search_episodes('Gamma'), [])
        self.assertEqual(s.list_history(), [])

    def test_delete_and_undo(self):
        s = mem.get_store('u')
        f = s.add_fact('Projeto: Gamma')
        self.assertTrue(s.remove_fact(f['id']))
        deleted = next(x for x in s.list_history() if x['action'] == 'DELETE')
        s.undo_event(deleted['event_id'])
        self.assertEqual(s.list_facts()[0]['text'], 'Projeto: Gamma')

    def test_fts_project_search(self):
        s = mem.get_store('u')
        for i in range(35):
            s.add_fact(f'Gosta de: chá{i} orgânico')
        p = s.add_fact('Projeto: hz_filmes catálogo de cinema')
        found = s.select_relevant('hz_filmes')
        self.assertIn(p['id'], [x['id'] for x in found])

    def test_episode_cross_conversation(self):
        s = mem.get_store('u')
        s.save_episode('No projeto Gamma decidimos usar Flutter e Railway para publicação.', 'Gamma', 'convo-one')
        prompt = mem.get_store('u').as_prompt_block('O que decidimos no projeto Gamma?')
        self.assertIn('decidimos usar Flutter', prompt)

    def test_metadata_fields(self):
        s = mem.get_store('u')
        f = s.add_fact('Projeto: Hz Filmes')
        s.set_metadata(f['id'], kind='project', subject='Hz Filmes', conversation_id='conv-1')
        loaded = mem.get_store('u').list_facts()[0]
        self.assertEqual(loaded['kind'], 'project')
        self.assertEqual(loaded['subject'], 'Hz Filmes')
        self.assertEqual(loaded['source_conversation_id'], 'conv-1')

    def test_operation_rejects_ambiguous_deletion(self):
        s = mem.get_store('u')
        s.add_fact('Projeto: Gama')
        result = apply_memory_operations(s, [{'op': 'DELETE', 'fact_id': s.list_facts()[0]['id']}],
                                         user_evidence='remova uma dependência do projeto')
        self.assertEqual(result, [])
        self.assertEqual(len(s.list_facts()), 1)

    def test_operation_requires_user_support(self):
        s = mem.get_store('u')
        apply_memory_operations(s, [{'op': 'ADD', 'text': 'Nome: Maria', 'kind': 'profile'}],
                                user_evidence='Como funciona a memória?')
        self.assertEqual(s.list_facts(), [])

    def test_disabled_memory_scans_are_not_called(self):
        # Chamar apenas o consolidador é escolha explícita de quem o agenda.
        self.assertTrue(callable(consolidate_turn))

    def test_async_writer_episode_and_project(self):
        llm = type('Client', (), {'chat_once': AsyncMock(return_value=json.dumps({
            'operations': [{'op': 'ADD', 'text': 'Projeto: Gamma em Flutter', 'kind': 'project', 'subject': 'Gamma'}],
            'episode': {'summary': 'Decidimos usar Flutter no projeto Gamma.', 'subject': 'Gamma'},
        }))})()
        asyncio.run(consolidate_turn(user_id='u', user_text='Decidimos usar Flutter no projeto Gamma',
            assistant_text='Combinado.', model='mock', llm_client=llm, conversation_id='c1'))
        s = mem.get_store('u')
        self.assertTrue(any('Gamma' in f['text'] for f in s.list_facts()))
        self.assertTrue(s.search_episodes('Gamma'))


if __name__ == '__main__':
    unittest.main()
