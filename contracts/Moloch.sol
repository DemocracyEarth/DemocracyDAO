// Goals
// - Defensibility -> Kick out malicious members via forceRagequit
// - Separation of Wealth and Power -> voting / loot tokens - grant pool can't be claimed (controlled by separate contract?)
// - batch proposals -> 1 month between proposal batches, 2 week voting period, 2 week grace period
// - better spam protection -> exponential increase in deposit for same member / option to claim deposit
// - replacing members?
//   - hasn't been discussed
// - accountability to stakeholders
//   - some kind of siganlling

pragma solidity 0.5.3;

import "./oz/SafeMath.sol";
import "./oz/IERC20.sol";
import "./GuildBank.sol";


contract Moloch {
    using SafeMath for uint256;

    /***************
    GLOBAL CONSTANTS
    ***************/
    uint256 public periodDuration; // default = 17280 = 4.8 hours in seconds (5 periods per day)
    uint256 public votingPeriodLength; // default = 35 periods (7 days)
    uint256 public gracePeriodLength; // default = 35 periods (7 days)
    uint256 public abortWindow; // default = 5 periods (1 day)
    uint256 public proposalDeposit; // default = 10 ETH (~$1,000 worth of ETH at contract deployment)
    uint256 public dilutionBound; // default = 3 - maximum multiplier a YES voter will be obligated to pay in case of mass ragequit
    uint256 public processingReward; // default = 0.1 - amount of ETH to give to whoever processes a proposal
    uint256 public summoningTime; // needed to determine the current period
    bool public quadraticMode; // if it will computed quadratic votes over traditional ones.

    IERC20 public approvedToken; // approved token contract reference; default = wETH
    GuildBank public guildBank; // guild bank contract reference

    // HARD-CODED LIMITS
    // These numbers are quite arbitrary; they are small enough to avoid overflows when doing calculations
    // with periods or shares, yet big enough to not limit reasonable use cases.
    uint256 constant MAX_VOTING_PERIOD_LENGTH = 10**18; // maximum length of voting period
    uint256 constant MAX_GRACE_PERIOD_LENGTH = 10**18; // maximum length of grace period
    uint256 constant MAX_DILUTION_BOUND = 10**18; // maximum dilution bound
    uint256 constant MAX_NUMBER_OF_SHARES = 10**18; // maximum number of shares that can be minted

    /***************
    EVENTS
    ***************/
    event SubmitProposal(
        uint256 proposalIndex,
        address indexed delegateKey,
        address indexed memberAddress,
        address[] indexed candidates,
        uint256 tokenTribute,
        uint256 sharesRequested
    );
    event SubmitVote(
        uint256 proposalIndex,
        address indexed delegateKey,
        address indexed memberAddress,
        address indexed candidate,
        uint256 votes,
        uint256 quadraticVotes
    );
    event ProcessProposal(
        uint256 indexed proposalIndex,
        address indexed electedCandidate,
        address indexed memberAddress,
        uint256 tokenTribute,
        uint256 sharesRequested,
        bool didPass
    );
    event Ragequit(address indexed memberAddress, uint256 sharesToBurn);
    event Abort(uint256 indexed proposalIndex, address applicantAddress);
    event UpdateDelegateKey(
        address indexed memberAddress,
        address newDelegateKey
    );
    event SummonComplete(address indexed summoner, uint256 shares);

    /******************
    INTERNAL ACCOUNTING
    ******************/
    uint256 public totalShares = 0; // total shares across all members
    uint256 public totalSharesRequested = 0; // total shares that have been requested in unprocessed proposals

    struct Ballot {
        uint256[] votes;
        uint256[] quadraticVotes;
        address[] candidate;
    }

    struct Member {
        address delegateKey; // the key responsible for submitting proposals and voting - defaults to member address unless updated
        uint256 shares; // the # of shares assigned to this member
        bool exists; // always true once a member has been created
        uint256 highestIndexVote; // highest proposal index # on which the member voted YES
    }

    struct Proposal {
        address proposer; // the member who submitted the proposal
        address[] candidates; // list of candidates to include in a ballot
        uint256[] totalVotes; // total votes each candidate received
        uint256[] totalQuadraticVotes; // calculation of quadratic votes for each candidate
        uint256 sharesRequested; // the # of shares the applicant is requesting
        uint256 startingPeriod; // the period in which voting can start for this proposal
        uint256 yesVotes; // the total number of YES votes for this proposal
        uint256 noVotes; // the total number of NO votes for this proposal
        bool processed; // true only if the proposal has been processed
        bool didPass; // true only if the proposal has elected a candidate
        address electedCandidate; // address of an electeed candidate
        bool aborted; // true only if applicant calls "abort" fn before end of voting period
        uint256 tokenTribute; // amount of tokens offered as tribute
        string details; // proposal details - could be IPFS hash, plaintext, or JSON
        uint256 maxTotalSharesAtYesVote; // the maximum # of total shares encountered at a yes vote on this proposal
        mapping(address => Ballot) votesByMember; // list of candidates and corresponding votes
    }

    mapping(address => Member) public members;
    mapping(address => address) public memberAddressByDelegateKey;
    Proposal[] public proposalQueue;

    /********
    MODIFIERS
    ********/
    modifier onlyMember {
        require(
            members[msg.sender].shares > 0,
            "Moloch::onlyMember - not a member"
        );
        _;
    }

    modifier onlyDelegate {
        require(
            members[memberAddressByDelegateKey[msg.sender]].shares > 0,
            "Moloch::onlyDelegate - not a delegate"
        );
        _;
    }

    /********
    FUNCTIONS
    ********/
    constructor(
        address summoner,
        address _approvedToken,
        uint256 _periodDuration,
        uint256 _votingPeriodLength,
        uint256 _gracePeriodLength,
        uint256 _abortWindow,
        uint256 _proposalDeposit,
        uint256 _dilutionBound,
        uint256 _processingReward,
        bool _quadraticMode
    ) public {
        require(
            summoner != address(0),
            "Moloch::constructor - summoner cannot be 0"
        );
        require(
            _approvedToken != address(0),
            "Moloch::constructor - _approvedToken cannot be 0"
        );
        require(
            _periodDuration > 0,
            "Moloch::constructor - _periodDuration cannot be 0"
        );
        require(
            _votingPeriodLength > 0,
            "Moloch::constructor - _votingPeriodLength cannot be 0"
        );
        require(
            _votingPeriodLength <= MAX_VOTING_PERIOD_LENGTH,
            "Moloch::constructor - _votingPeriodLength exceeds limit"
        );
        require(
            _gracePeriodLength <= MAX_GRACE_PERIOD_LENGTH,
            "Moloch::constructor - _gracePeriodLength exceeds limit"
        );
        require(
            _abortWindow > 0,
            "Moloch::constructor - _abortWindow cannot be 0"
        );
        require(
            _abortWindow <= _votingPeriodLength,
            "Moloch::constructor - _abortWindow must be smaller than or equal to _votingPeriodLength"
        );
        require(
            _dilutionBound > 0,
            "Moloch::constructor - _dilutionBound cannot be 0"
        );
        require(
            _dilutionBound <= MAX_DILUTION_BOUND,
            "Moloch::constructor - _dilutionBound exceeds limit"
        );
        require(
            _proposalDeposit >= _processingReward,
            "Moloch::constructor - _proposalDeposit cannot be smaller than _processingReward"
        );

        approvedToken = IERC20(_approvedToken);

        guildBank = new GuildBank(_approvedToken);

        periodDuration = _periodDuration;
        votingPeriodLength = _votingPeriodLength;
        gracePeriodLength = _gracePeriodLength;
        abortWindow = _abortWindow;
        proposalDeposit = _proposalDeposit;
        dilutionBound = _dilutionBound;
        processingReward = _processingReward;
        quadraticMode = _quadraticMode;

        summoningTime = now;

        members[summoner] = Member(summoner, 1, true, 0);
        memberAddressByDelegateKey[summoner] = summoner;
        totalShares = 1;

        emit SummonComplete(summoner, 1);
    }

    /*****************
    PROPOSAL FUNCTIONS
    *****************/

    function submitProposal(
        address[] memory candidates,
        uint256 tokenTribute,
        uint256 sharesRequested,
        string memory details
    ) public payable onlyDelegate {
        require(
            candidates.length > 0,
            "QuadraticMoloch::submitProposal - at least 1 candidate is required."
        );
        for (uint256 i = 0; i < candidates.length; i++) {
            require(
                candidates[i] != address(0),
                "Moloch::submitProposal - candidate cannot be 0"
            );
        }

        // Make sure we won't run into overflows when doing calculations with shares.
        // Note that totalShares + totalSharesRequested + sharesRequested is an upper bound
        // on the number of shares that can exist until this proposal has been processed.
        require(
            totalShares.add(totalSharesRequested).add(sharesRequested) <=
                MAX_NUMBER_OF_SHARES,
            "Moloch::submitProposal - too many shares requested"
        );

        totalSharesRequested = totalSharesRequested.add(sharesRequested);

        address memberAddress = memberAddressByDelegateKey[msg.sender];

        // collect proposal deposit from proposer and store it in the Moloch until the proposal is processed
        require(
            approvedToken.transferFrom(
                msg.sender,
                address(this),
                proposalDeposit
            ),
            "Moloch::submitProposal - proposal deposit token transfer failed"
        );

        // collect tribute from candidate list and store it in the Moloch until the proposal is processed
        for (uint256 k = 0; k < candidates.length; k++) {
            require(
                approvedToken.transferFrom(
                    candidates[k],
                    address(this),
                    tokenTribute
                ),
                "Moloch::submitProposal - tribute token transfer failed"
            );
        }

        // compute startingPeriod for proposal
        uint256 startingPeriod = max(
            getCurrentPeriod(),
            proposalQueue.length == 0
                ? 0
                : proposalQueue[proposalQueue.length.sub(1)].startingPeriod
        )
            .add(1);

        uint256[] memory totalVotesmemory;
        uint256[] memory totalquadrativVotesmemory;
        // create proposal ...
        Proposal memory proposal = Proposal({
            proposer: memberAddress,
            candidates: candidates,
            totalVotes: totalVotesmemory,
            totalQuadraticVotes: totalquadrativVotesmemory,
            sharesRequested: sharesRequested,
            startingPeriod: startingPeriod,
            yesVotes: 0,
            noVotes: 0,
            processed: false,
            didPass: false,
            electedCandidate: address(0x0),
            aborted: false,
            tokenTribute: tokenTribute,
            details: details,
            maxTotalSharesAtYesVote: 0
        });

        // ... and append it to the queue
        proposalQueue.push(proposal);

        uint256 proposalIndex = proposalQueue.length.sub(1);
        emit SubmitProposal(
            proposalIndex,
            msg.sender,
            memberAddress,
            candidates,
            tokenTribute,
            sharesRequested
        );
    }

    function submitVote(
        uint256 proposalIndex,
        address candidate,
        uint256 votes
    ) public onlyDelegate {
        address memberAddress = memberAddressByDelegateKey[msg.sender];
        Member storage member = members[memberAddress];

        require(
            proposalIndex < proposalQueue.length,
            "Moloch::submitVote - proposal does not exist"
        );
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(
            votes > 0,
            "QuadraticMoloch::submitVote - at least one vote must be cast"
        );
        require(
            getCurrentPeriod() >= proposal.startingPeriod,
            "Moloch::submitVote - voting period has not started"
        );
        require(
            !hasVotingPeriodExpired(proposal.startingPeriod),
            "Moloch::submitVote - proposal voting period has expired"
        );
        require(
            !proposal.aborted,
            "Moloch::submitVote - proposal has been aborted"
        );

        // store vote
        Ballot storage memberBallot = proposal.votesByMember[memberAddress];

        uint256 totalVotes = 0;
        uint256 newVotes = 0;
        bool update = false;
        uint256 quadraticVotes = 0;
        for (uint256 i = 0; i < memberBallot.candidate.length; i++) {
            if (memberBallot.candidate[i] == candidate) {
                update = true;
                newVotes = memberBallot.votes[i].add(votes);
                quadraticVotes = sqrt(newVotes);
                memberBallot.votes[i] = newVotes;
                memberBallot.quadraticVotes[i] = quadraticVotes;
            }
            totalVotes = totalVotes.add(memberBallot.votes[i]);
        }
        require(
            totalVotes <= member.shares,
            "QuadraticMoloch::submitVote - not enough shares to cast this quantity of votes"
        );

        if (!update) {
            memberBallot.candidate.push(candidate);
            memberBallot.votes.push(votes);
            quadraticVotes = sqrt(votes);
            memberBallot.quadraticVotes.push(quadraticVotes);
            proposal.votesByMember[memberAddress] = memberBallot;
        }

        // count vote
        update = false;
        for (uint256 k = 0; k < proposal.candidates.length; k++) {
            if (proposal.candidates[k] == candidate) {
                proposal.totalVotes[k] = proposal.totalVotes[k].add(votes);
                proposal.totalQuadraticVotes[k] = sqrt(proposal.totalVotes[k]);
                update = true;
            }
        }
        if (!update) {
            proposal.candidates.push(candidate);
            proposal.totalVotes.push(votes);
            proposal.totalQuadraticVotes.push(sqrt(votes));
        }

        if (proposalIndex > member.highestIndexVote) {
            member.highestIndexVote = proposalIndex;
        }

        emit SubmitVote(
            proposalIndex,
            msg.sender,
            memberAddress,
            candidate,
            votes,
            quadraticVotes
        );
    }

    function processProposal(uint256 proposalIndex) public {
        require(
            proposalIndex < proposalQueue.length,
            "Moloch::processProposal - proposal does not exist"
        );
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(
            getCurrentPeriod() >=
                proposal.startingPeriod.add(votingPeriodLength).add(
                    gracePeriodLength
                ),
            "Moloch::processProposal - proposal is not ready to be processed"
        );
        require(
            proposal.processed == false,
            "Moloch::processProposal - proposal has already been processed"
        );
        require(
            proposalIndex == 0 || proposalQueue[proposalIndex.sub(1)].processed,
            "Moloch::processProposal - previous proposal must be processed"
        );

        proposal.processed = true;
        totalSharesRequested = totalSharesRequested.sub(
            proposal.sharesRequested
        );

        // Get elected candidate
        uint256 largest = 0;
        uint256 elected = 0;
        require(
            proposal.totalVotes.length > 0,
            "QuadraticMoloch::processProposal - this proposal has not received any votes."
        );
        bool didPass = true;
        uint256 i;
        for (i = 0; i < proposal.totalVotes.length; i++) {
            if (quadraticMode) {
                if (proposal.totalQuadraticVotes[i] > largest) {
                    largest = proposal.totalQuadraticVotes[i];
                    elected = i;
                }
            } else if (proposal.totalVotes[i] > largest) {
                largest = proposal.totalVotes[i];
                elected = i;
            }
        }
        proposal.electedCandidate = proposal.candidates[i];

        // Make the proposal fail if the dilutionBound is exceeded
        if (totalShares.mul(dilutionBound) < proposal.maxTotalSharesAtYesVote) {
            didPass = false;
        }

        // PROPOSAL PASSED
        if (didPass && !proposal.aborted) {
            proposal.didPass = true;

            // if the elected candidate is already a member, add to their existing shares
            if (members[proposal.electedCandidate].exists) {
                members[proposal.electedCandidate].shares = members[proposal
                    .electedCandidate]
                    .shares
                    .add(proposal.sharesRequested);

                // the applicant is a new member, create a new record for them
            } else {
                // if the applicant address is already taken by a member's delegateKey, reset it to their member address
                if (
                    members[memberAddressByDelegateKey[proposal
                        .electedCandidate]]
                        .exists
                ) {

                        address memberToOverride
                     = memberAddressByDelegateKey[proposal.electedCandidate];
                    memberAddressByDelegateKey[memberToOverride] = memberToOverride;
                    members[memberToOverride].delegateKey = memberToOverride;
                }

                // use elected candidate address as delegateKey by default
                members[proposal.electedCandidate] = Member(
                    proposal.electedCandidate,
                    proposal.sharesRequested,
                    true,
                    0
                );
                memberAddressByDelegateKey[proposal.electedCandidate] = proposal
                    .electedCandidate;
            }

            // mint new shares
            totalShares = totalShares.add(proposal.sharesRequested);

            // transfer tokens to guild bank
            require(
                approvedToken.transfer(
                    address(guildBank),
                    proposal.tokenTribute
                ),
                "Moloch::processProposal - token transfer to guild bank failed"
            );

            // PROPOSAL FAILED OR ABORTED
        } else {
            // return all tokens to the applicant
            require(
                approvedToken.transfer(
                    proposal.electedCandidate,
                    proposal.tokenTribute
                ),
                "Moloch::processProposal - failing vote token transfer failed"
            );
        }

        // send msg.sender the processingReward
        require(
            approvedToken.transfer(msg.sender, processingReward),
            "Moloch::processProposal - failed to send processing reward to msg.sender"
        );

        // return deposit to proposer (subtract processing reward)
        require(
            approvedToken.transfer(
                proposal.proposer,
                proposalDeposit.sub(processingReward)
            ),
            "Moloch::processProposal - failed to return proposal deposit to proposer"
        );

        emit ProcessProposal(
            proposalIndex,
            proposal.electedCandidate,
            proposal.proposer,
            proposal.tokenTribute,
            proposal.sharesRequested,
            didPass
        );
    }

    function ragequit(uint256 sharesToBurn) public onlyMember {
        uint256 initialTotalShares = totalShares;

        Member storage member = members[msg.sender];

        require(
            member.shares >= sharesToBurn,
            "Moloch::ragequit - insufficient shares"
        );

        require(
            canRagequit(member.highestIndexVote),
            "Moloch::ragequit - cant ragequit until highest index proposal member voted YES on is processed"
        );

        // burn shares
        member.shares = member.shares.sub(sharesToBurn);
        totalShares = totalShares.sub(sharesToBurn);

        // instruct guildBank to transfer fair share of tokens to the ragequitter
        require(
            guildBank.withdraw(msg.sender, sharesToBurn, initialTotalShares),
            "Moloch::ragequit - withdrawal of tokens from guildBank failed"
        );

        emit Ragequit(msg.sender, sharesToBurn);
    }

    function abort(uint256 proposalIndex) public {
        require(
            proposalIndex < proposalQueue.length,
            "Moloch::abort - proposal does not exist"
        );
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(
            msg.sender == proposal.proposer,
            "Moloch::abort - msg.sender must be applicant"
        );
        require(
            getCurrentPeriod() < proposal.startingPeriod.add(abortWindow),
            "Moloch::abort - abort window must not have passed"
        );
        require(
            !proposal.aborted,
            "Moloch::abort - proposal must not have already been aborted"
        );

        uint256 tokensToAbort = proposal.tokenTribute;
        proposal.tokenTribute = 0;
        proposal.aborted = true;

        // return all tokens to the applicant
        require(
            approvedToken.transfer(proposal.proposer, tokensToAbort),
            "Moloch::processProposal - failed to return tribute to applicant"
        );

        emit Abort(proposalIndex, msg.sender);
    }

    function updateDelegateKey(address newDelegateKey) public onlyMember {
        require(
            newDelegateKey != address(0),
            "Moloch::updateDelegateKey - newDelegateKey cannot be 0"
        );

        // skip checks if member is setting the delegate key to their member address
        if (newDelegateKey != msg.sender) {
            require(
                !members[newDelegateKey].exists,
                "Moloch::updateDelegateKey - cant overwrite existing members"
            );
            require(
                !members[memberAddressByDelegateKey[newDelegateKey]].exists,
                "Moloch::updateDelegateKey - cant overwrite existing delegate keys"
            );
        }

        Member storage member = members[msg.sender];
        memberAddressByDelegateKey[member.delegateKey] = address(0);
        memberAddressByDelegateKey[newDelegateKey] = msg.sender;
        member.delegateKey = newDelegateKey;

        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }

    /***************
    GETTER FUNCTIONS
    ***************/

    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function getCurrentPeriod() public view returns (uint256) {
        return now.sub(summoningTime).div(periodDuration);
    }

    function getProposalQueueLength() public view returns (uint256) {
        return proposalQueue.length;
    }

    // can only ragequit if the latest proposal you voted YES on has been processed
    function canRagequit(uint256 highestIndexVote) public view returns (bool) {
        require(
            highestIndexVote < proposalQueue.length,
            "Moloch::canRagequit - proposal does not exist"
        );
        return proposalQueue[highestIndexVote].processed;
    }

    function hasVotingPeriodExpired(uint256 startingPeriod)
        public
        view
        returns (bool)
    {
        return getCurrentPeriod() >= startingPeriod.add(votingPeriodLength);
    }

    function getMemberProposalVote(address memberAddress, uint256 proposalIndex)
        public
        view
        returns (uint256)
    {
        require(
            members[memberAddress].exists,
            "Moloch::getMemberProposalVote - member doesn't exist"
        );
        require(
            proposalIndex < proposalQueue.length,
            "Moloch::getMemberProposalVote - proposal doesn't exist"
        );
        return
            proposalQueue[proposalIndex].votesByMember[memberAddress]
                .votes
                .length;
    }
}
