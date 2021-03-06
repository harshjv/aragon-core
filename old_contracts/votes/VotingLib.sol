pragma solidity ^0.4.8;

import "zeppelin/token/ERC20.sol";
import "../stocks/GovernanceToken.sol";

library VotingLib {
  struct Voting {
    mapping (uint8 => uint256) optionVotes; // option n -> totalVotes (absolute votes)
    mapping (address => uint8) votedOption; // voter -> voted option (0 = hasn't voted, 1 = removed delegated vote, 10 + n = voted option n)
    mapping (address => mapping (address => uint256)) voters; // voter -> governance token -> tokens voted
    mapping (address => mapping (address => uint256)) overruledVotes; // delegate -> governance token -> overruledVotes (absolute votes)
    address[] governanceTokens;
    uint256 totalCastedVotes;
    address votingAddress;
    uint64 startTimestamp;
    uint64 closeTimestamp;
    uint8 executed;
    bool isClosed;
    bool isExecuted;
  }

  struct Votings {
    Voting[] votings;
    mapping (address => uint256) reverseVotings;
    uint256[] openedVotings;
  }

  function init(Votings storage self) {
    self.votings.length += 1;
  }

  function votingAddress(Votings storage self, uint256 votingId) returns (address) {
    return self.votings[votingId].votingAddress;
  }

  function votingIndex(Votings storage self, address votingAddress) returns (uint256) {
    return self.reverseVotings[votingAddress];
  }

  function getVotingInfo(Votings storage self, uint256 votingId) returns (address votingAddress, uint64 startDate, uint64 closeDate, bool isExecuted, uint8 executed, bool isClosed) {
    Voting voting = self.votings[votingId];
    return (voting.votingAddress, voting.startTimestamp, voting.closeTimestamp, voting.isExecuted, voting.executed, voting.isClosed);
  }

  function createVoting(Votings storage self, address votingAddress, address[] governanceTokens, uint64 closeTimestamp, uint64 startTimestamp) returns (uint256 votingId) {
    if (self.reverseVotings[votingAddress] > 0) throw;
    if (now > startTimestamp) throw;
    if (startTimestamp > closeTimestamp) throw;

    self.votings.length += 1;
    votingId = self.votings.length - 1;
    Voting storage voting = self.votings[votingId];

    voting.votingAddress = votingAddress;
    voting.governanceTokens = governanceTokens;
    voting.startTimestamp = startTimestamp;
    voting.closeTimestamp = closeTimestamp;

    if (voting.governanceTokens.length < 1) throw;

    self.openedVotings.push(votingId);
    self.reverseVotings[votingAddress] = votingId;

    NewVoting(votingId, votingAddress, startTimestamp, closeTimestamp);
  }

  function canModifyVote(Votings storage self, address voter, uint256 votingId) constant returns (bool) {
    Voting voting = self.votings[votingId];
    if (now > voting.closeTimestamp) return false; // poll is closed by date
    if (now < voting.startTimestamp) return false; // poll has not opened
    if (voting.isClosed || voting.isExecuted) return false; // poll has been executed
    if (voter == address(this)) return false; // non assigned stock cannot vote
    return true;
  }

  function canVote(Votings storage self, address voter, uint256 votingId) constant returns (bool) {
    if (!canModifyVote(self, voter, votingId)) return false;

    Voting voting = self.votings[votingId];
    for (uint j = 0; j < voting.governanceTokens.length; j++) {
      GovernanceToken token = GovernanceToken(voting.governanceTokens[j]);
      uint256 votes = token.votingPowerForDelegate(voter) - voting.overruledVotes[voter][token];
      if (token.votingPower() > 0 && (votes > voting.voters[voter][token] || voting.votedOption[voter] == 1)) return true; // can vote using token.
    }
    return false;
  }

  function votingPowerForVoting(Votings storage self, uint256 votingId, address voter) constant public returns (uint256 votable, uint256 modificable, uint8 voted) {
    Voting voting = self.votings[votingId];

    address oldVoter;
    if (!canModifyVote(self, voter, votingId)) return (0, 0, voting.votedOption[voter]);

    votable = 0;
    modificable = 0;

    for (uint j = 0; j < voting.governanceTokens.length; j++) {
      GovernanceToken token = GovernanceToken(voting.governanceTokens[j]);

      if (token.balanceOf(voter) < 1) continue;

      bool isDelegated = token.votingPowerForDelegate(voter) == 0 && token.balanceOf(voter) - voting.voters[voter][token] > 0;
      oldVoter = isDelegated ? token.votingDelegate(voter) : voter;

      uint modificableVotes;
      uint remainingVotes;

      if (isDelegated) {
        uint castedDelegatedVotes = voting.voters[oldVoter][token] > 0 ? (token.balanceOf(voter) - voting.voters[voter][token] - voting.overruledVotes[voter][token]) : (voter == oldVoter ? voting.voters[voter][token] : 0 );
        modificableVotes = voting.votedOption[voter] != 1 ? castedDelegatedVotes : 0;
        remainingVotes = voting.votedOption[voter] == 1 ? castedDelegatedVotes : 0;
      } else {
        modificableVotes = voting.voters[voter][token] - voting.overruledVotes[voter][token];
        remainingVotes = token.votingPowerForDelegate(voter) == 0 ? 0 : token.votingPowerForDelegate(voter) - voting.voters[voter][token] - voting.overruledVotes[voter][token];
      }

      votable += remainingVotes * token.votingPower();
      modificable += modificableVotes * token.votingPower();
    }

    voted = voting.votedOption[oldVoter] > 1 ? voting.votedOption[oldVoter] : 0;

    if (!canVote(self, voter, votingId)) return (0, modificable, voted);
    return (votable, modificable, voted);
  }

  function indexOf(uint256[] array, uint256 element) returns (int256) {
    for (uint256 i = 0; i < array.length; i++) {
      if (array[i] == element) return int256(i);
    }
    return -1;
  }

  function castVote(Votings storage self, uint256 votingId, address voter, uint8 vote) returns (bool voted) {
    if (!canVote(self, voter, votingId)) throw;

    Voting voting = self.votings[votingId];
    for (uint j = 0; j < voting.governanceTokens.length; j++) {
      GovernanceToken token = GovernanceToken(voting.governanceTokens[j]);

      uint remainingVotes = token.votingPowerForDelegate(voter) - voting.voters[voter][token];
      if (voting.votedOption[voter] == 1) {
        remainingVotes = token.balanceOf(voter);
      }
      uint addingVotes = token.votingPower() * (remainingVotes - voting.overruledVotes[voter][token]);

      voting.voters[voter][token] += remainingVotes;
      voting.optionVotes[vote] += addingVotes;
      voting.totalCastedVotes += addingVotes;

      if (addingVotes > 0) voted = true;

      if (voting.votedOption[voter] > 1 && voting.votedOption[voter] != 10 + vote) throw; // cant vote different things
      voting.votedOption[voter] = 10 + vote; // avoid 0
    }

    if (voted) VoteCasted(votingId, voting.votingAddress, voter);
  }

  function modifyVote(Votings storage self, uint256 votingId, address voter, uint8 vote, bool removes) {
    if (!canModifyVote(self, voter, votingId)) throw;

    Voting voting = self.votings[votingId];

    if (!hasVoted(self, votingId, voter)) throw;

    for (uint j = 0; j < voting.governanceTokens.length; j++) {
      GovernanceToken token = GovernanceToken(voting.governanceTokens[j]);
      uint remainingVotes = token.balanceOf(voter) - voting.voters[voter][token];
      uint votingPowerPerToken = token.votingPower();

      bool isDelegated = token.votingPowerForDelegate(voter) == 0 && remainingVotes > 0;
      address oldVoter = isDelegated ? token.votingDelegate(voter) : voter;

      if (voting.votedOption[oldVoter] == 0) throw;

      if (isDelegated) {
        // over-write delegate vote
        if (voting.votedOption[voter] == 1) throw; // delegate logic not works if has already voted

        voting.overruledVotes[oldVoter][token] += remainingVotes;
        // voting.voters[oldVoter][token] -= remainingVotes;
        if (voting.votedOption[voter] > 1) {
          remainingVotes = token.balanceOf(voter);
        }
        voting.optionVotes[voting.votedOption[oldVoter] - 10] -= remainingVotes * votingPowerPerToken;

        if (removes) {
          voting.votedOption[voter] = 1; // overruled by removing
          voting.voters[voter][token] = 0;
          voting.totalCastedVotes -= remainingVotes * votingPowerPerToken;
        } else {
          voting.votedOption[voter] = 10 + vote;
          voting.voters[voter][token] = remainingVotes;
          voting.optionVotes[vote] += remainingVotes * votingPowerPerToken;
        }
      } else {
        uint totalVotes = voting.voters[voter][token] - voting.overruledVotes[voter][token];
        voting.optionVotes[voting.votedOption[oldVoter] - 10] -= totalVotes * votingPowerPerToken;
        uint modifyingVotes = totalVotes * votingPowerPerToken;

        // set only at the end
        if (j == voting.governanceTokens.length - 1) voting.votedOption[voter] = removes ? 0 : 10 + vote;

        if (removes) {
          voting.voters[voter][token] -= modifyingVotes;
          voting.totalCastedVotes -= modifyingVotes;
        } else {
          voting.optionVotes[vote] += modifyingVotes;
        }
      }
    }

    VoteCasted(votingId, voting.votingAddress, voter);
  }

  function addGovernanceToken(Votings storage self, address governanceToken) {
    for (uint j = 0; j < self.openedVotings.length; j++) {
      Voting voting = self.votings[self.openedVotings[j]];
      voting.governanceTokens.push(governanceToken);
    }
  }

  function hasVotedInOpenedVoting(Votings storage self, address voter) returns (bool) {
    for (uint j = 0; j < self.openedVotings.length; j++) {
      if (hasVoted(self, self.openedVotings[j], voter)) return true;
    }

    return false;
  }

  function hasVoted(Votings storage self, uint256 votingId, address voter) returns (bool) {
    Voting voting = self.votings[votingId];
    for (uint j = 0; j < voting.governanceTokens.length; j++) {
      GovernanceToken token = GovernanceToken(voting.governanceTokens[j]);
      if (voting.votedOption[token.votingDelegate(voter)] > 0) {
        if (voting.votedOption[voter] != 1) return true; // not overruled
      }
    }
    return false;
  }

  function countVotes(Votings storage self, uint256 votingId, uint8 option) returns (uint256 votes, uint256 totalCastedVotes, uint256 votingPower) {
    Voting voting = self.votings[votingId];

    totalCastedVotes = voting.totalCastedVotes;
    votes = voting.optionVotes[option];
    for (uint j = 0; j < voting.governanceTokens.length; j++) {
      GovernanceToken token = GovernanceToken(voting.governanceTokens[j]);
      uint256 normalTotalSupply = token.totalSupply();
      uint256 parentTotalSupply = token.parentTotalSupply();
      uint256 totalSupply = normalTotalSupply > parentTotalSupply ? normalTotalSupply : parentTotalSupply;
      votingPower += (totalSupply - token.balanceOf(this)) * token.votingPower();
    }
  }

  // Company knows when it can be closed, nothing to be checked here
  function closeExecutedVoting(Votings storage self, uint256 votingId, uint8 option) {
    Voting voting = self.votings[votingId];
    if (voting.isExecuted) throw;
    voting.executed = option;
    voting.isExecuted = true;
    if (!voting.isClosed) closeVoting(self, votingId);

    VoteExecuted(votingId, voting.votingAddress, option);
  }

  function closeVoting(Votings storage self, uint256 votingId) {
    Voting voting = self.votings[votingId];
    if (voting.isClosed && now < voting.closeTimestamp) throw; // Not executed nor closed by time
    voting.isClosed = true;
    int256 i = indexOf(self.openedVotings, votingId);
    if (i < 0) throw;

    // Remove from array without keeping its order
    if (self.openedVotings.length > 1) {
      // Move last element to the place of the removing item
      self.openedVotings[uint256(i)] = self.openedVotings[self.openedVotings.length - 1];
    }
    // Remove last item
    self.openedVotings.length -= 1;
  }

  event NewVoting(uint256 id, address votingAddress, uint64 starts, uint64 closes);
  event VoteCasted(uint256 id, address votingAddress, address voter);
  event VoteExecuted(uint256 id, address votingAddress, uint8 outcome);
}
