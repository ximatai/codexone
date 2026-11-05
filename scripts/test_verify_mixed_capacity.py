#!/usr/bin/env python3
"""Fixture and responsibility checks; no Docker or provider access."""
import base64
import json
import unittest
from verify_mixed_capacity import MIB, exact_body, image_body, assert_ledger, recovery_medians


class MixedCapacityTests(unittest.TestCase):
    def test_wire_boundary_includes_envelope(self):
        for size in (8*MIB-1024, 9*MIB, 32*MIB):
            body = exact_body(size, 'mixed-boundary')
            self.assertEqual(len(body), size)
            self.assertEqual(json.loads(body)['input'], 'mixed-boundary')

    def test_large_output_is_valid_multi_item_json(self):
        body = image_body()
        self.assertTrue(45*MIB < len(body) < 47*MIB)
        rows = json.loads(body)['data']
        self.assertEqual(len(rows), 8)
        for row in rows:
            self.assertLess(len(row['b64_json']), 8*MIB)
            artifact = base64.b64decode(row['b64_json'], validate=True)
            self.assertGreater(len(artifact), 4*MIB)
            self.assertTrue(artifact.startswith(b'GIF89a'))
            self.assertTrue(artifact.endswith(b'\x00\x3b'))

    def test_unknown_cannot_disappear_or_change_owner(self):
        valid = [{'principal':'synthetic-mixed-0','state':'settled','count':9,'reserved':0,'complete':9},
                 {'principal':'synthetic-mixed-1','state':'settled','count':6,'reserved':0,'complete':6},
                 {'principal':'synthetic-mixed-2','state':'settled','count':9,'reserved':0,'complete':9},
                 {'principal':'synthetic-mixed-2','state':'unknown','count':3,'reserved':3,'complete':0},
                 {'principal':'synthetic-mixed-3','state':'settled','count':3,'reserved':0,'complete':3}]
        assert_ledger(valid)
        for index, change in ((3, {'state':'settled'}), (3, {'reserved':0}),
                              (3, {'principal':'synthetic-mixed-0'}), (3, {'state':'intent'}),
                              (1, {'state':'unknown','reserved':6}), (0, {'complete':8})):
            rows = [dict(row) for row in valid]
            rows[index].update(change)
            with self.assertRaises(AssertionError): assert_ledger(rows)
        edits_unknown = [dict(row) for row in valid]
        edits_unknown[-1].update(state='unknown', reserved=3, complete=0)
        assert_ledger(edits_unknown)
        old_false_positive = [dict(row) for row in valid]
        old_false_positive[1].update(state='unknown',count=9,reserved=9,complete=0)
        old_false_positive.pop()
        with self.assertRaises(AssertionError): assert_ledger(old_false_positive)

    def test_recovery_uses_warmed_first_round_and_rejects_growth(self):
        def samples(values):
            return [{'phase':f'round-{turn+1}-recovery','rssBytes':value*MIB}
                    for turn,value in enumerate(values) for _ in range(30)]
        self.assertEqual(recovery_medians(samples([300,320,332])), [300*MIB,320*MIB,332*MIB])
        with self.assertRaises(AssertionError): recovery_medians(samples([300,320,333]))
        with self.assertRaises(AssertionError): recovery_medians(samples([300,320,320])[:-10])


if __name__ == '__main__': unittest.main()
