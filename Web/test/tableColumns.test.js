// Pure layout rules, run with `npm test` (node, no browser).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { distribute } from '../src/tableColumns.js'

const sum = (list) => list.reduce((a, b) => a + b, 0)
const close = (a, b) => assert.ok(Math.abs(a - b) < 0.01, `${a} ≈ ${b}`)

test('a table that fits fills the width: half the spare equally, half by natural width', () => {
  const out = distribute([100, 300], [100, 128], 1000)
  close(sum(out), 1000)
  // spare 600: 150 each equally, then 75 / 225 by width
  close(out[0], 100 + 150 + 75)
  close(out[1], 300 + 150 + 225)
})

test('a short column keeps its natural width when the long one must wrap', () => {
  const out = distribute([110, 2000], [110, 128], 900, 384)
  assert.equal(out[0], 110)
  close(out[1], 790)
})

test('one very long column does not starve another wrapping column', () => {
  // naturals 3000 and 500, minimums 128 each, 900 available, weight cap 384
  const out = distribute([3000, 500], [128, 128], 900, 384)
  close(sum(out), 900)
  assert.ok(out[1] >= 300, `second column got ${out[1]}`)
})

test('a column never gets more than its natural width while others still lack', () => {
  const out = distribute([3000, 200, 150], [128, 128, 150], 1000, 384)
  assert.ok(out[1] <= 200)
  close(sum(out), 1000)
})

test('when even the minimums do not fit, columns get their minimums', () => {
  assert.deepEqual(distribute([1000, 1000], [400, 400], 600), [400, 400])
})
