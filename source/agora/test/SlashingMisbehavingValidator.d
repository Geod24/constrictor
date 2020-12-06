/*******************************************************************************

    Contains tests for re-routing part of the frozen UTXO of a slashed
    validater to `CommonsBudget` address.

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.test.SlashingMisbehavingValidator;

version (unittest):

import agora.common.crypto.Key;
import agora.common.Config;
import agora.common.Hash;
import agora.consensus.data.Block;
import agora.consensus.data.Params;
import agora.consensus.data.PreImageInfo;
import agora.consensus.data.Transaction;
import agora.consensus.EnrollmentManager;
import agora.consensus.state.UTXODB;
import agora.network.NetworkManager;
import agora.utils.Test;
import agora.test.Base;

import core.stdc.stdint;
import core.stdc.time;
import core.thread;

import geod24.Registry;

// This derived `EnrollmentManager` does not reveal any preimages
// after enrollment.
private class MissingPreImageEM : EnrollmentManager
{
    ///
    public this (string db_path, KeyPair key_pair,
        immutable(ConsensusParams) params)
    {
        super(db_path, key_pair, params);
    }

    /// This does not reveal pre-images intentionally
    public override bool getNextPreimage (out PreImageInfo preimage,
        Height height) @safe
    {
        return false;
    }
}

// This derived TestValidatorNode does not reveal any preimages using the
// `MissingPreImageEM` class
private class NoPreImageVN : TestValidatorNode
{
    public static shared UTXOSet utxo_set;

    ///
    public this (Config config, Registry* reg, immutable(Block)[] blocks,
        in TestConf test_conf, shared(time_t)* cur_time)
    {
        super(config, reg, blocks, test_conf, cur_time);
    }

    protected override EnrollmentManager getEnrollmentManager (
        string data_dir, in ValidatorConfig validator_config,
        immutable(ConsensusParams) params)
    {
        return new MissingPreImageEM(":memory:", validator_config.key_pair,
            params);
    }

    protected override UTXOSet getUtxoSet(string data_dir)
    {
        this.utxo_set = cast(shared UTXOSet)super.getUtxoSet(data_dir);
        return cast(UTXOSet)this.utxo_set;
    }
}

/// Situation: A misbehaving validator does not reveal its preimages right after
///     it's enrolled.
/// Expectation: The information about the validator is stored in a block.
///     The validator is un-enrolled and a part of its fund is refunded to the
///     validators with the 10K of the fund going to the `CommonsBudget` address.
unittest
{
    static class BadAPIManager : TestAPIManager
    {
        ///
        public this (immutable(Block)[] blocks, TestConf test_conf,
            time_t initial_time)
        {
            super(blocks, test_conf, initial_time);
        }

        ///
        public override void createNewNode (Config conf, string file, int line)
        {
            if (this.nodes.length == 5)
            {
                auto time = new shared(time_t)(this.initial_time);
                auto api = RemoteAPI!TestAPI.spawn!NoPreImageVN(
                    conf, &this.reg, this.blocks, this.test_conf,
                    time, conf.node.timeout);
                this.reg.register(conf.node.address, api.tid());
                this.nodes ~= NodePair(conf.node.address, api, time);
            }
            else
                super.createNewNode(conf, file, line);
        }
    }

    TestConf conf = {
        recurring_enrollment : false,
    };
    auto network = makeTestNetwork!BadAPIManager(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();

    auto nodes = network.clients;
    auto spendable = network.blocks[$ - 1].spendable().array;
    auto utxo_set = cast(UTXOSet) NoPreImageVN.utxo_set;
    auto bad_address = nodes[5].getPublicKey();

    // discarded UTXOs (just to trigger block creation)
    auto txs = spendable[0 .. 8].map!(txb => txb.sign()).array;

    // wait for the preimage to be missed
    Thread.sleep(5.seconds);

    // block 1
    txs.each!(tx => nodes[0].putTransaction(tx));
    network.expectBlock(Height(1));

    // block 2
    txs = txs.map!(tx => TxBuilder(tx).sign()).array();
    txs.each!(tx => nodes[0].putTransaction(tx));
    network.expectBlock(Height(2));
    auto block2 = nodes[0].getBlocksFrom(2, 1)[0];
    assert(block2.header.missing_validators.length == 1);
}
