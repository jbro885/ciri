# frozen_string_literal: true

# Copyright (c) 2018, by Jiang Jinyang. <https://justjjy.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


require 'forwardable'
require_relative 'chain/block'
require_relative 'chain/header'
require_relative 'chain/transaction'

module Ciri

  # Chain manipulate logic
  # store via rocksdb
  class Chain

    # HeaderChain
    # store headers
    class HeaderChain
      HEAD = 'head'
      GENESIS = 'genesis'
      PREFIX = 'h'
      TD_SUFFIX = 't'
      NUM_SUFFIX = 'n'

      attr_reader :store

      def initialize(store)
        @store = store
      end

      def head
        encoded = store[HEAD]
        encoded && Header.rlp_decode!(encoded)
      end

      def head=(header)
        store[HEAD] = header.rlp_encode!
      end

      def get_header(hash)
        encoded = store[PREFIX + hash]
        encoded && Header.rlp_decode!(encoded)
      end

      def valid?(header)
        parent_header = get_header(header.parent_hash)
        return false unless parent_header

        # check height
        return false unless parent_header.number + 1 == header.number

        # check timestamp
        return false unless parent_header.timestamp < header.timestamp

        # check gas limit range
        parent_gas_limit = parent_header.gas_limit
        gas_limit_max = parent_gas_limit + parent_gas_limit / 1024
        gas_limit_min = parent_gas_limit - parent_gas_limit / 1024
        gas_limit = header.gas_limit
        return false unless gas_limit >= 5000 && gas_limit > gas_limit_min && gas_limit < gas_limit_max
        return false unless calculate_difficulty(header, parent_header) == header.difficulty

        # TODO check POW

        true
      end

      # calculate header difficulty
      # you can find explain in Ethereum yellow paper: Block Header Validity section.
      def calculate_difficulty(header, parent_header)
        return header.difficulty if header.number == 0
        x = parent_header.difficulty / 2048
        y = header.ommers_hash == Utils::BLANK_SHA3 ? 1 : 2
        time_factor = [y - (header.timestamp - parent_header.timestamp) / 9, -99].max
        # difficulty bomb
        fake_height = [(header.number - 3000000), 0].max
        height_factor = 2 ** (fake_height / 100000 - 2)
        [header.difficulty, parent_header.difficulty + x * time_factor + height_factor].max
      end

      # write header
      def write(header)
        hash = header.hash
        # get total difficulty
        td = if header.number == 0
               header.difficulty
             else
               parent_header = get_header(header.parent_hash)
               raise "can't find parent from db" unless parent_header
               parent_td = total_difficulty(parent_header.hash)
               parent_td + header.difficulty
             end
        # write header and td
        store.batch do |b|
          b.put(PREFIX + hash, header.rlp_encode!)
          b.put(PREFIX + hash + TD_SUFFIX, RLP.encode(td, Integer))
        end
      end

      def write_header_hash_number(header_hash, number)
        enc_number = Utils.big_endian_encode number
        store[PREFIX + enc_number + NUM_SUFFIX] = header_hash
      end

      def get_header_hash_by_number(number)
        enc_number = Utils.big_endian_encode number
        store[PREFIX + enc_number + NUM_SUFFIX]
      end

      def total_difficulty(header_hash = head.hash)
        RLP.decode(store[PREFIX + header_hash + TD_SUFFIX], Integer)
      end
    end

    extend Forwardable

    PREFIX = 'b'

    def_delegators :@header_chain, :head, :total_difficulty

    attr_reader :genesis, :network_id, :store

    def initialize(store, genesis:, network_id:)
      @store = store
      @header_chain = HeaderChain.new(store)
      @genesis = genesis
      @network_id = network_id
      load_or_init_store
    end

    def genesis_hash
      genesis.hash
    end

    def current_block
      store.get(PREFIX + head.hash)
    end

    def current_height
      head.number
    end

    def insert_blocks(blocks)
      # valid blocks
      blocks.each do |block|
        write_block block
      end
    end

    def get_block(hash)
      encoded = store[PREFIX + hash]
      encoded && BLock.rlp_decode!(encoded)
    end

    def write_block(block)
      #TODO save block to db
      # valid header
      @header_chain.write(block.header)
      store[PREFIX + block.header.hash] = block.rlp_encode!
      # valid chain
      # check td
      # update head
      # reorg chain
    end

    private

    def load_or_init_store
      # write genesis block, is chain head not exists
      if head.nil?
        write_block(genesis)
      end
    end
  end

end