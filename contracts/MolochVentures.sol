// Goals
// - Safe Approvals (two-phase)
// - Multi-applicant proposals
// - ERC20 support
// - ERC20 rebalancing
// - Vote delegation
// - Fund Safety
// - Guild Kick
// - Spam Protection
// - Contract Interaction
// - Separation of Voting Power and Capital

// Usage Patterns To Support
// - rDAI investing (interest rate swaps)
// - provide liquidity on uniswap
// - open a CDP

// Safe Approvals (two-phase)
// - function stageProposal
//   - can be called by anyone
//   - escrows funds
//   - specifies shares / proposal details
// - function submitProposal
//   - members only
// - function abortProposal
//   - any applicant of the proposal

// Multi-applicant proposals
// - stageProposal takes address[], shares[]
//   - allow multi-token tribute per member?

// ERC20 Support
// - ERC20 whitelist + safeRedeem
// - proposal field for "whitelistToken"
// - whitelist mapping
// - appovedTokens becomes array
//   - loop over it for ragequit
// - single token tribute / payment per proposal
// - If for whatever reason a whitelisted ERC20 breaks and can't be transferred
//   - add an escape hatch which triggers after 1 week of not processing the proposal
//   - if 1 week passes, the proposal is considered processed and failed
//     - no tribute is returned
//     - no payments are made
//     - no shares are minted
//   - make a special bool for this to indicate?
//     - escaped?

// ERC20 Rebalancing
// - Proposals to send and receive individual tokens

// Vote Delegation
// - updateDelegates(address[] delegates, uint[] votes)
//   - How to prevent double voting?
//     1. prevent updating delegate if delegate has already voted on a proposal in the voting period, force wait until grace period
//     2. track member whose delegated votes are being used, make sure total votes for a proposal does not exceed member shares
//      - tricky because we need to loop over all members that have delegated to an address when it votes, might require loop
//     3. enforce 1 week (= to voting period) cooldown period for re-assigning shares
//      - tricky because it becomes an attack vector
//     4. when a member votes, track all delegations to them and loop over them and record that the delegating member has voted with some of their shares
//      - actually we're changing the model from 100% votes to X% votes because of delegation...
//      - this means submitVote should allow partial votes?
//        - why would this matter? signalling
//   - How to prevent circular delegation?
//     - loop through delegation target, either we find a circle, run out of gas, or find the terminus
//       - if we run out of gas or find a circle, error / fail
//       - otherwise OK
// - use a two-way link for delegation
//   - address[] delegates
//   - uint[] delegateVotes
//   - mapping (address => uint) delegations; -> inside Member struct
//   - problem -> hard to update array of people who have delegated to you (constituents)
//     - might be easier to use a linked mapping -> replacing a single constituent doesn't need to re-org the whole array
//     - yes, use a linked list for this
// - how to track voting shares?
// - dumb / simple -> no recursive delegation, the delegate is the final recipient
//   - this allows delegation to only active voters, not other members that might also be delegating
// - cooldown period when you updateDelegates before you can vote again
//   - takes until your *highest* index proposal completes the voting period
//   - how to track for your other delegated votes?
//   - need to reverse lookup from delegated to member (loop over linked list of delegations to the member) and skip cooldown members
// - possible that enough members delegate to a single address that it exceeds the gas limit to loop over the delegating members and update them
//   - this is actually kind of hilarious, both as an attack and as way of preventing too much delegation to a single member
//   - TODO upper limit of delegations?
// - TODO
//   1. default delegate -> member for all shares
//   2. member struct
//    - delegate mapping
//   3. submitVote
//    - look up all members who have delegated to the delegate
// - TODO
//   - when you ragequit it is no longer enough to drop the # of shares...
//     - you have to go remove all the delegate votes that you had...
//   - track the # of shares per index that have votes, and that have voted yes
//     - store yes votes in an array / linked list
//     - loop through the yes votes to find out how many are active
//     - can ragequit the remaining shares
//   - ragequit takes an array of delegates and array of shares to ragequit per delegate
//     - check that the member has actually assigned that many shares to each delegate
//     - check total shares to ragequit doesn't exceed shares

// FUCKFUCK FUCK many-to-many delegation
// - 1. prevent voting after updating delegates until cooldown expires
// - 2. each delegate tracks highest index yes vote
// - 3. ragequit specifies the delegate addresses to exit and shares per address
//      - checks the highest index yes vote to see if you can ragequit each of those delegates
//      - what happens if I update delegate back to myself?
//      - I could keep a tally of shares I can ragequit, and when they are free again...
//        - how would it get reset?

// Fund Safety
// - keeper addresses that can also ragequit funds
//   - revisit moloch pool
// - whitelist of addresses that can be ragequit to
//   - must take some time to update
//     - use a constructor param
//   - if attacker has member key and member address isn't whitelisted, they have to update the whitelist first before they can ragequit to steal funds
//     - in this case, our best move is to ragequit the funds to a whitelisted address before the attacker adds their address to the whitelist
// - default is member address
// - must have at least 1 whitelist address
//   - track w/ "whitelist length"

// Guild Kick
// - proposal to burn shares for a member address
//   1. member address automatically receives tokens
//   2. to help with lost keys, we can also send the funds to an address besides the member address
//     1. obvious attack vector
//     2. might be redundant with authorized addresses to ragequit
//   3. burn shares but don’t give $
//     1. essentially forces member to ragequit to protect their $
// - decision -> only whitelisted addresses
//   - possibly skip this feature?
//   - different proposal type / function
//   - sharesToBurn -> use first applicant address and check that length is 1?
//     - allow burning multiple addresses in the same proposal
//     - allows redemptions of more liquid assets if desired
//   - processProposal -> if passing, call _ragequit
// - if we add array of delegates / votes to revoke during ragequit, we have to add it here too
//   - that increases complexity -> instead just burn all shares
//   - revoke all delegations -> does this require a loop?
//   - no, because it's an array that can be dropped
//     - but the votes delegated is a mapping... needs to be set to zero for each
//     - could set a bool on member "hasRagequit"
//       - implied by having "exists" and 0 shares
//       - prevent overriding old members -> edge case -> member ragequits 100% before they receive new shares as an applicant
//     - options:
//       1. [no] prevent members from ragequitting if they are an applicant
//       2. make the proposal fail if applicant has ragequit
//          - prevent proposals with applicants that have ragequit
//       3. members that have ragequit can still get more shares
//          - this means we need to reset all delegates when they ragequit
//          - cap the # of shares delegated per member -> possibly SQRT of shares 100 -> 10 delegates, 1000 -> 31.62
//          - this only works if 1 eth = 1 share or else #s grow a lot
//          - just cap it at 100? 99 -> hedge fund rules
//          - TODO Gas calculations... -> setting all the balances to 0 might actually provide gas

// Spam Protection
// - non-linearly increasing proposal deposit cost for the same member to submit multiple proposals
//  - processing fee as a % of proposal deposit
//  - donation as a % of proposal deposit to the Guild Bank (or a Pool)
//  - fee % and donation % can increase non-linearly as well-
// - accepts a param as the exponential rate (X ^ num proposals sponsored)
//   - store sponsored proposals on member
//   - increment on sponsor, deduct on processProposal
//     - leave unchanged on ragequit

// Contract Interaction
// - need a proxy function
//   - take contract address, payload
//   - https://github.com/uport-project/uport-identity/blob/develop/contracts/Proxy.sol
//   - https://github.com/gnosis/safe-contracts/blob/master/contracts/GnosisSafe.sol
//   - stefan says these functions are sufficient
//     - how do we approve the proposal contract to call Moloch functions?
//       - add the contract as an agent before the proxy call
//       - remove the contract as an agent after the proxy call
//       - keeping this atomic is important to prevent replay attacks
//     - which functions does the proposal contract need to call?
//       - withdraw multiple ERC20 by address from the guild bank
//       - can it do multi-applicant x multi-token?
//         - if the applicants escrow funds on the proposal contract directly instead of Moloch
//         - then all that would happen is the contract would transfer all their funds to the guild bank
//         - proposal contract would need to read from proposal pass/fail status and only send funds if passing, otherwise return
//       - scenario -> exchange tokens on uniswap
//         1. proxy contract calls withdraw tokens on Moloch to withdraw from guild bank -> moloch -> proxy
//         2. proxy contract calls exchange on uniswap (params ensure minimum slippage or tx fails)
//         3. if success -> send swapped tokens back to guild bank
//         4. if failure -> send original tokens back to the guild bank
//         - note -> failure cases need to be carefully coded to prevent error or theft
// - extremely dangerous if the proxy contract has a suicide function because then it could be replaced

// Separation of Voting Power and Capital
// - bring back Loot Tokens
// - TODO open for conversation
// - proposals specify loot tokens to mint
//   - convertSharesToLoot (shares -> loot tokens)
//   - ragequit wraps convertSharesToLoot -> redeemLootTokens
//   - redeemLootTokens (on guildbank or moloch?)

// Open Questions
// - Should we keep the 1 week voting / grace periods?

// TODO
// - create an aragon DAO
// - create a DAOStack DAO
// - EIP 1066 for standard return format

pragma solidity 0.5.3;

import "./oz/SafeMath.sol";
import "./oz/IERC20.sol";
import "./GuildBank.sol";

contract MolochVentures {
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

    IERC20 public depositToken; // reference to the deposit token
    GuildBank public guildBank; // guild bank contract reference

    // HARD-CODED LIMITS
    // These numbers are quite arbitrary; they are small enough to avoid overflows when doing calculations
    // with periods or shares, yet big enough to not limit reasonable use cases.
    uint256 constant MAX_VOTING_PERIOD_LENGTH = 10**18; // maximum length of voting period
    uint256 constant MAX_GRACE_PERIOD_LENGTH = 10**18; // maximum length of grace period
    uint256 constant MAX_DILUTION_BOUND = 10**18; // maximum dilution bound
    uint256 constant MAX_NUMBER_OF_SHARES = 10**18; // maximum number of shares that can be minted

    address public constant HEAD = address(0xdead);
    address public constant TAIL = address(0xbeef);

    uint256 public constant UINT_MAX = 2**256 - 1;

    /***************
    EVENTS
    ***************/
    event SubmitProposal(uint256 proposalIndex, address indexed delegateKey, address indexed memberAddress, address indexed applicant, uint256 tokenTribute, uint256 sharesRequested);
    event SubmitVote(uint256 indexed proposalIndex, address indexed delegateKey, address indexed memberAddress, uint8 uintVote);
    event ProcessProposal(uint256 indexed proposalIndex, address indexed applicant, address indexed memberAddress, uint256 tokenTribute, uint256 sharesRequested, bool didPass);
    event Ragequit(address indexed memberAddress, uint256 sharesToBurn);
    event Abort(uint256 indexed proposalIndex, address applicantAddress);
    event UpdateDelegateKey(address indexed memberAddress, address newDelegateKey);
    event SummonComplete(address indexed summoner, uint256 shares);

    /******************
    INTERNAL ACCOUNTING
    ******************/
    uint256 public proposalCount = 0; // total proposals submitted
    uint256 public totalShares = 0; // total shares across all members
    uint256 public totalSharesRequested = 0; // total shares that have been requested in unprocessed proposals

    address authorizedProxy = address(0); // used to authorize proxy contracts to execute functions

    enum Vote {
        Null, // default value, counted as abstention
        Yes,
        No
    }

    // Linked list item for proposal votes by member
    struct LinkedVote {
        uint256 proposalIndex;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 nextProposalIndex;
    }

    // might not be necessary to track highestIndexVote for when updating delegates
    // - if we track delegate proposal votes and prevent double voting, even if more votes are delegated to a delegate, they won't be able to vote again
    // - in theory, this means I could have 1000 shares, allocate 500 to a delegate, have them vote, then update to allocate 500 to a different delegate, and then let them vote
    // - if I tried to do this a third time it would fail, because I would exceed the total number of shares I have to vote on this proposal
    //   - edge case -> what if I get new shares?
    //     - if they are assigned to a delegate that has already voted (your primary delegate) then they can't vote on a proposal
    //       - I can update delegate right before if I really want to
    //     - if they are assigned to a delegate that has NOT voted then they can vote

    struct Member {
        uint256 shares; // the # of shares assigned to this member
        bool exists; // always true once a member has been created
        // uint256 highestIndexVote; // highest proposal index # on which the member voted YES or NO - used to prevent double voting when updating delegates
        address[] delegateKeys; // delegates responsible for submitting proposals and voting - defaults to member address unless updated
        mapping (address => uint256) delegatedVotes; // votes assigned to each delegate
        mapping (uint256 => LinkedVote) linkedVotes; // yes and no votes per proposal, stored as a linked list
    }

    struct Proposal {
        address proposer; // the member who submitted the proposal
        address[] applicants; // the applicant who wishes to become a member - this key will be used for withdrawals
        uint256[] sharesRequested; // the # of shares the applicant is requesting
        uint256[] tokenTributes; // amount of tokens offered as tribute
        address tributeToken; // token being offered as tribute
        uint256[] paymentsRequested; // the payments requested for each applicant
        address paymentToken; // token to send payment in
        address proxyAddress; // address of proxy contract to interact with
        bytes proxyPayload; // payload to send to proxy contract
        uint256 startingPeriod; // the period in which voting can start for this proposal
        uint256 yesVotes; // the total number of YES votes for this proposal
        uint256 noVotes; // the total number of NO votes for this proposal
        bool sponsored; // true only if the proposal has been submitted by a member
        bool processed; // true only if the proposal has been processed
        bool didPass; // true only if the proposal passed
        bool aborted; // true only if applicant calls "abort" fn before end of voting period
        string details; // proposal details - could be IPFS hash, plaintext, or JSON
        uint256 maxTotalSharesAtYesVote; // the maximum # of total shares encountered at a yes vote on this proposal
        address tokenToWhitelist; // the address of the token to add to the whitelist
        mapping (address => Vote) votesByDelegate; // the votes on this proposal by each delegate
    }

    mapping (address => IERC20) public tokenWhitelist;
    IERC20[] approvedTokens;

    mapping (address => bool) public proposedToWhitelist; // true if a token has been proposed to the whitelist (to avoid duplicate whitelist proposals)

    mapping (address => Member) public members;
    mapping (address => Delegate) public delegates;

    // proposals by ID
    mapping (uint => Proposal) public proposals;

    // TODO have this be an array of proposalIds to prevent duplicate storage
    Proposal[] public proposalQueue;

    /********
    MODIFIERS
    ********/
    modifier onlyMember {
        require(members[msg.sender].shares > 0, "Moloch::onlyMember - not a member");
        _;
    }

    modifier onlyDelegate {
        require(members[memberAddressByDelegateKey[msg.sender]].shares > 0, "Moloch::onlyDelegate - not a delegate");
        _;
    }

    modifier onlyAuthorizedProxy {
        require(msg.sender == authorizedProxy); // must be called by authorizedProxy
        _;
    }

    /********
    FUNCTIONS
    ********/

    constructor(
        address summoner,
        address _approvedTokens,
        uint256 _periodDuration,
        uint256 _votingPeriodLength,
        uint256 _gracePeriodLength,
        uint256 _abortWindow,
        uint256 _proposalDeposit,
        uint256 _dilutionBound,
        uint256 _processingReward
    ) public {
        require(summoner != address(0), "Moloch::constructor - summoner cannot be 0");
        require(_periodDuration > 0, "Moloch::constructor - _periodDuration cannot be 0");
        require(_votingPeriodLength > 0, "Moloch::constructor - _votingPeriodLength cannot be 0");
        require(_votingPeriodLength <= MAX_VOTING_PERIOD_LENGTH, "Moloch::constructor - _votingPeriodLength exceeds limit");
        require(_gracePeriodLength <= MAX_GRACE_PERIOD_LENGTH, "Moloch::constructor - _gracePeriodLength exceeds limit");
        require(_abortWindow > 0, "Moloch::constructor - _abortWindow cannot be 0");
        require(_abortWindow <= _votingPeriodLength, "Moloch::constructor - _abortWindow must be smaller than or equal to _votingPeriodLength");
        require(_dilutionBound > 0, "Moloch::constructor - _dilutionBound cannot be 0");
        require(_dilutionBound <= MAX_DILUTION_BOUND, "Moloch::constructor - _dilutionBound exceeds limit");
        require(_proposalDeposit >= _processingReward, "Moloch::constructor - _proposalDeposit cannot be smaller than _processingReward");
        require(_approvedTokens.length > 0); // at least 1 approved token

        // first approved token is the deposit token
        depositToken = IERC20(_approvedTokens[0]);

        for (var i=0; i < _approvedTokens.length; i++) {
            require(_approvedToken != address(0), "Moloch::constructor - _approvedToken cannot be 0");
            require(!tokenWhitelist[_approvedTokens[i]], "Moloch::constructor - duplicate approved token");
            tokenWhitelist[_approvedTokens[i]] = IERC20(_approvedTokens[i]);
            approvedTokens.push(IERC20(_approvedTokens[i]));
        }

        guildBank = new GuildBank(address(this));

        periodDuration = _periodDuration;
        votingPeriodLength = _votingPeriodLength;
        gracePeriodLength = _gracePeriodLength;
        abortWindow = _abortWindow;
        proposalDeposit = _proposalDeposit;
        dilutionBound = _dilutionBound;
        processingReward = _processingReward;

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
        address[] applicants,
        uint256[] sharesRequested,
        uint256[] tokenTributes,
        address tributeToken,
        uint256[] paymentsRequested,
        address paymentToken,
        address proxyAddress,
        bytes proxyPayload,
        string memory details
    )
        public
    {
        require(applicant != address(0), "Moloch::submitProposal - applicant cannot be 0");

        require(applicants.length == sharesRequested.length);
        require(applicants.length == tokenTributes.length);
        require(applicants.length == paymentsRequested.length);

        // TODO make sure this works
        require(tokenWhitelist[tributeToken]);
        require(tokenWhitelist[paymentToken]);

        // create proposal ...
        Proposal memory proposal = Proposal({
            proposer: address(0),
            applicants: applicants,
            sharesRequested: sharesRequested,
            tokenTributes: tokenTributes,
            tributeToken: tributeToken,
            paymentsRequested; paymentsRequested,
            paymentToken: paymentToken,
            startingPeriod: 0,
            yesVotes: 0,
            noVotes: 0,
            sponsored: false,
            processed: false,
            didPass: false,
            aborted: false,
            details: details,
            tokenToWhitelist: address(0),
            maxTotalSharesAtYesVote: 0
        });

        proposals[proposalCount] = proposal; // save proposal by its id
        proposalCount += 1; // increment proposal counter
    }

    function submitWhitelistProposal(address tokenToWhitelist) public {
        require(tokenToWhitelist != address(0), "Moloch::submitProposal - applicant cannot be 0");
        require(!tokenWhitelist[tokenToWhitelist]); // can't already have whitelisted the token

        // create proposal ...
        // TODO - figure out empty array default values
        Proposal memory proposal = Proposal({
            proposer: address(0),
            applicants: applicants,
            sharesRequested: sharesRequested,
            tokenTributes: tokenTributes,
            tributeToken: address(0),
            paymentsRequested; paymentsRequested,
            paymentToken: address(0),
            startingPeriod: 0,
            yesVotes: 0,
            noVotes: 0,
            sponsored: false,
            processed: false,
            didPass: false,
            aborted: false,
            details: details,
            tokenToWhitelist: tokenToWhitelist,
            maxTotalSharesAtYesVote: 0
        });

        proposals[proposalCount] = proposal; // save proposal by its id
        proposalCount += 1; // increment proposal counter
    }

    function sponsorProposal(
        uint256 proposalId
    )
        public
        onlyDelegate
    {
        address memberAddress = memberAddressByDelegateKey[msg.sender];

        // collect proposal deposit from proposer and store it in the Moloch until the proposal is processed
        require(depositToken.transferFrom(msg.sender, address(this), proposalDeposit), "Moloch::submitProposal - proposal deposit token transfer failed");

        Proposal memory proposal = proposals[proposalId];

        // token whitelist proposal
        if (proposal.tokenToWhitelist != address(0)) {
            require(!proposedToWhitelist[proposal.tokenToWhitelist]); // already an active proposal to whitelist this token
            proposedToWhitelist[proposal.tokenToWhitelist] = true;

        // standard proposal
        } else {
            for (var j=0; j < proposal.applicants.length; j++) {
                // collect tribute from applicant and store it in the Moloch until the proposal is processed
                require(IERC20(proposal.tributeToken).transferFrom(proposal.applicants[j], address(this), proposal.tokenTributes[j]), "Moloch::submitProposal - tribute token transfer failed");
            }

            uint256 memory proposalSharesRequested = 0;
            for (var i=0; i < proposal.sharesRequested.length; i++) {
                proposalSharesRequested = proposalSharesRequested + proposal.sharesRequested[i];
            }

            // Make sure we won't run into overflows when doing calculations with shares.
            // Note that totalShares + totalSharesRequested + sharesRequested is an upper bound
            // on the number of shares that can exist until this proposal has been processed.
            require(totalShares.add(totalSharesRequested).add(proposalSharesRequested) <= MAX_NUMBER_OF_SHARES, "Moloch::submitProposal - too many shares requested");

            totalSharesRequested = totalSharesRequested.add(proposalSharesRequested);
        }

        require(!proposal.sponsored, "Moloch::sponsorProposal - proposal has already been sponsored");

        // compute startingPeriod for proposal
        uint256 startingPeriod = max(
            getCurrentPeriod(),
            proposalQueue.length == 0 ? 0 : proposalQueue[proposalQueue.length.sub(1)].startingPeriod
        ).add(1);

        proposal.startingPeriod = startingPeriod;
        proposal.proposer = msg.sender;

        // ... and append it to the queue
        proposalQueue.push(proposal);

        uint256 proposalIndex = proposalQueue.length.sub(1);
        // TODO emit SponsorProposal(proposalIndex, msg.sender, memberAddress, applicant, tokenTribute, sharesRequested);
    }

    // TODO provide the members to vote on behalf of as a param
    // - means we don't have to store delegate references to members
    // - can lookup via param and check the member -> delegate relationship and vote amounts
    // - still need to loop over proposals per member to update YES VOTE index for preventing ragequits
    // - still makes sense for that to be a linked list to avoid reforming the whole array
    // - still needs to be looped over (starting from highest index) during inserts to find the proposal index
    // - looped over again during ragequit to calculate amount of shares that can be ragequit
    //   - start from highest index, loop back counting up
    //   - [prev index, yes votes, next index]
    //   - 3:[1, 100, 7] -> 7:[3, 200, 9] -> 9:[...]
    //   - are no votes important? only for updateDelegates?
    //     - if updateDelegates just adds a cooldown period, then the votes dont matter because future ones are prevented regardless
    //   - instead of [prev index, yes votes, next index], it can just be [votes, next]
    //     - when I submitVote, I provide the array of prev indexes for each member that I lookup
    //       - if it points to nothing (first vote), replace
    //       - if it points to a higher index, insert before
    //       - if it points to lower index, insert after
    //       - if it points to the the same index, update the # of yes votes
    //   - still need to loop during ragequits
    //     - even if we provide prev to the highest vote there can be multiple yes votes
    //     - could calculate running totals but that would shift looping to the delegate
    //     - people vote more often than they ragequit, so better to keep the loop on ragequit


    function submitVote(uint256 proposalIndex, uint8 uintVote, address[] votingMembers, uint256[] prevMemberVotes) public onlyDelegate {
        Delegate delegate = delegates[msg.sender];
        // TODO modifier onlyDelegate
        require(delegate.totalVotes > 0);

        require(votingMembers.length = prevMemberVotes.length);

        require(proposalIndex < proposalQueue.length, "Moloch::submitVote - proposal does not exist");
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(uintVote < 3, "Moloch::submitVote - uintVote must be less than 3");
        Vote vote = Vote(uintVote);

        require(proposal.votesByDelegate[msg.sender] == Vote.Null, "Moloch::submitVote - delegate has already voted on this proposal");
        require(vote == Vote.Yes || vote == Vote.No, "Moloch::submitVote - vote must be either Yes or No");
        require(!proposal.aborted, "Moloch::submitVote - proposal has been aborted");

        uint256 totalVotes = 0;
        for (var i=0; i < votingMembers.length; i++) {
            Member storage member = members[votingMembers[i]];
            uint256 delegatedVotes = member.delegatedVotes[msg.sender];
            require(delegatedVotes > 0); // member has not delegated any votes to this delegate


            // check whether the member can vote on this proposal
            // - lookup votes by the prevMemberVotes
            // - needs to resolve to either the index of this proposal or one higher
            LinkedVote storage linkedVote = member.linkedVotes[prevMemberVotes[i]];
            require(linkedVote.proposalIndex >= proposalIndex);

            // member has voted on this proposal already, add to their votes
            if (linkedVote.proposalIndex == proposalIndex) {
                require(linkedVote.yesVotes.add(linkedVote.noVotes).add(delegatedVotes) <= member.shares); // votes per proposal can't exceed shares

                if (vote == Vote.Yes) {
                    linkedVote.yesVotes = linkedVote.yesVotes.add(delegatedVotes);
                } else if (vote == Vote.No) {
                    linkedVote.noVotes = linkedVote.noVotes.add(delegatedVotes);
                }
            }

            proposal.votesByDelegate[msg.sender] = vote;
            totalVotes = totalVotes.add(delegatedVotes);
        }

        // count vote
        if (vote == Vote.Yes) {
            proposal.yesVotes = proposal.yesVotes.add(totalVotes);

            // set maximum of total shares encountered at a yes vote - used to bound dilution for yes voters
            if (totalShares > proposal.maxTotalSharesAtYesVote) {
                proposal.maxTotalSharesAtYesVote = totalShares;
            }

        } else if (vote == Vote.No) {
            proposal.noVotes = proposal.noVotes.add(totalVotes);
        }

        // emit SubmitVote(proposalIndex, msg.sender, memberAddress, uintVote);
    }

    // TODO
    // - proposalQueue to track ids of proposals, then lookup by mapping
    function processProposal(uint256 proposalIndex) public {
        require(proposalIndex < proposalQueue.length, "Moloch::processProposal - proposal does not exist");
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(getCurrentPeriod() >= proposal.startingPeriod.add(votingPeriodLength).add(gracePeriodLength), "Moloch::processProposal - proposal is not ready to be processed");
        require(proposal.processed == false, "Moloch::processProposal - proposal has already been processed");
        require(proposalIndex == 0 || proposalQueue[proposalIndex.sub(1)].processed, "Moloch::processProposal - previous proposal must be processed");

        // TODO probably better to save total shares requested for a proposal to avoid needing to compute via loops multiple times
        uint256 memory proposalSharesRequested = 0;
        for (var i=0; i < proposal.sharesRequested.length; i++) {
            proposalSharesRequested = proposalSharesRequested + proposal.sharesRequested[i];
        }

        proposal.processed = true; // will prevent re-entry of this function from the proxy call
        totalSharesRequested = totalSharesRequested.sub(proposal.proposalSharesRequested);

        bool didPass = proposal.yesVotes > proposal.noVotes;

        // Make the proposal fail if the dilutionBound is exceeded
        if (totalShares.mul(dilutionBound) < proposal.maxTotalSharesAtYesVote) {
            didPass = false;
        }

        // Possibly compute and store at submission?
        uint256 totalPaymentRequested = 0;
        for (var x=0; x < paymentsRequested.length; x++) {
            totalPaymentsRequested = totalPaymentsRequested + paymentsRequested[x];
        }

        // Make sure there is enough tokens for payments, or auto-fail
        if (IERC20(proposal.paymentToken).balanceOf(address(guildBank)) >= totalPaymentsRequested) {
            didPass = false;
        }

        // Note - We execute the proxy transaction here so that if it fails we can make the proposal fail
        if (didPass && !proposal.aborted) {
            authorizedProxy = proposal.proxyAddress;
            // TODO
            // - very important that the proxy contract is audited to ensure that it returns true if it succeeds
            // - otherwise it could withdraw tokens and still receive tribute tokens back
            if (!executeCall(proposal.proxyAddress, proposal.proxyPayload)) {
                didPass = false
            }
            authorizedProxy = address(0);
        }

        // PROPOSAL PASSED
        if (didPass && !proposal.aborted) {

            proposal.didPass = true;

            // whitelist proposal passed, add token to whitelist
            if (proposal.tokenToWhitelist != address(0)) {
               tokenWhitelist[tokenToWhitelist] = IERC20(tokenToWhitelist);
               approvedTokens.push(IERC20(tokenToWhitelist));

            // standard proposal passed, collect tribute, send payments, mint shares
            } else {

                for (var j=0; j < proposal.applicants.length; j++) {
                    address applicant = proposal.applicants[j];
                    uint256 sharesRequested = proposal.sharesRequested[j];
                    // if the applicant is already a member, add to their existing shares
                    if (members[applicant].exists) {
                        Member storage member = members[applicant];
                        member.shares = member.shares.add(sharesRequested);

                        address primaryDelegate = member.delegateKeys[0];

                        // assign new shares as voting power to the first delegate key for this member
                        member.delegatedVotes[primaryDelegate] = member.delegatedVotes[primaryDelegate].add(sharesRequested);
                        delegates[primaryDelegate].totalVotes = delegates[primaryDelegate].totalVotes.add(sharesRequested);

                        // TODO how to add votes to the delegate for this member?
                        // - add the votes to the member address as its own delegate
                        // - how? update the linked list? increase total votes?
                        // - which delegate should get the new shares? the first one?

                    // the applicant is a new member, create a new record for them
                    } else {
                        // scenario - delegate exists and is delegated to by others
                        // - then that delegate also becomes a member, and by default receives all the member shares as delegated votes
                        // - initial: { totalVotes: 100, HEAD -> member 1 -> TAIL }
                        // - final: { totalVotes: 200, HEAD -> member 2 -> member 1 -> TAIL }

                        Delegate storage delegate = delegates[applicant];

                        // TODO possibly refactor to combine this if/else into 1 statement
                        // - if/else just becomes what the applicant points to in the linked list
                        // if the applicant address is already a delegate, update the delegate with the new shares
                        if (delegate.totalVotes > 0) {
                            delegate.totalVotes = delegate.totalVotes.add(sharesRequested);

                            // TODO refactor to use a insertBefore function for linked lists
                            // update the linked list of members for the delegate to include the applicant before the first linked member
                            address firstLinkedMemberAddress = delegate.linkedMembers[HEAD].nextMember;
                            LinkedMember firstLinkedMember = delegate.linkedMembers[firstLinkedMemberAddress];
                            delegate.linkedMembers[HEAD].nextMember = applicant;
                            delegate.linkedMembers[applicant] = LinkedMember(HEAD, firstLinkedMemberAddress);
                            delegate.linkedMembers[firstLinkedMemberAddress].prevMember = applicant;

                        // if the applicant address is not already being delegated to, instantiate the delegate
                        } else {
                            delegate.totalVotes = sharesRequested;
                            delegate.linkedMembers[HEAD] = LinkedMember(address(0), applicant);
                            delegate.linkedMembers[applicant] = LinkedMember(HEAD, TAIL);
                            delegate.linkedMembers[TAIL] = LinkedMember(applicant, address(0));
                        }

                        // create a new member record - default use member address as the only delegate
                        members[applicant] = Member(shares, true, 0, 0);
                        members[applicant].delegateKeys.push(applicant);
                        members[applicant].delegatedVotes[applicant] = sharesRequested;
                        members[applicant].linkedVotes[0] = LinkedVote(0, 0, UINT_MAX);
                        members[applicant].linkedVotes[UINT_MAX] = LinkedVote(0, 0, 0);
                    }

                    // TODO technically this doesn't have to be looped over because it could be aggregated and sent once
                    // transfer tokens to guild bank
                    require(
                        IERC20(proposal.tributeToken).transfer(address(guildBank), proposal.tokenTributes[j]),
                        "Moloch::processProposal - token transfer to guild bank failed"
                    );

                    // What happens if there aren't enough tokens to pay?
                    // - We should check that the total balance in the guildbank is greater than the sum of the payments
                    // - If it isn't proposal auto-fails
                    require(
                        guildBank.withdrawToken(proposal.paymentToken, applicant, proposal.paymentsRequested[j]),
                        "Moloch::processProposal - token payment to applicant failed"
                    );
                }

                // mint new shares
                totalShares = totalShares.add(proposalSharesRequested);
            }

        // PROPOSAL FAILED OR ABORTED
        } else {
            for (var k=0; k < proposal.applicants.length; k++) {
                // return all tokens to the applicants
                require(
                    proposal.tributeToken.transfer(proposal.applicants[k], proposal.tokenTributes[k]),
                    "Moloch::processProposal - failing vote token transfer failed"
                );
            }
        }

        // if token whitelist proposal, remove token from tokens proposed to whitelist
        if (proposal.tokenToWhitelist != address(0)) {
            proposedToWhitelist[proposal.tokenToWhitelist] = false;
        }

        // send msg.sender the processingReward
        require(
            depositToken.transfer(msg.sender, processingReward),
            "Moloch::processProposal - failed to send processing reward to msg.sender"
        );

        // return deposit to proposer (subtract processing reward)
        require(
            depositToken.transfer(proposal.proposer, proposalDeposit.sub(processingReward)),
            "Moloch::processProposal - failed to return proposal deposit to proposer"
        );

        /* TODO
        emit ProcessProposal(
            proposalIndex,
            proposal.applicants,
            proposal.proposer,
            proposal.tokenTributes,
            proposal.sharesRequested,
            didPass
        );*/
    }

    function ragequit(uint256 sharesToBurn) public onlyMember {
        _ragequit(sharesToBurn, approvedTokens);

        emit Ragequit(msg.sender, sharesToBurn);
    }

    function safeRagequit(uint256 sharesToBurn, address[] tokenList) public onlyMember {
        // all tokens in tokenList must be in the tokenWhitelist
        for (var i=0; i < tokenList.length; i++) {
            require(tokenWhitelist[tokenList[i]]);
        }

        _ragequit(sharesToBurn, tokenList);

        // TODO emit SafeRagequit(msg.sender, sharesToBurn, tokenList);
    }

    function _ragequit(uint256 sharesToBurn, address[] approvedTokens) internal {
        uint256 initialTotalShares = totalShares;

        Member storage member = members[msg.sender];

        require(member.shares >= sharesToBurn, "Moloch::ragequit - insufficient shares");

        require(canRagequit(member.highestIndexYesVote), "Moloch::ragequit - cant ragequit until highest index proposal member voted YES on is processed");

        // burn shares
        member.shares = member.shares.sub(sharesToBurn);
        totalShares = totalShares.sub(sharesToBurn);

        // instruct guildBank to transfer fair share of tokens to the ragequitter
        require(
            guildBank.withdraw(msg.sender, sharesToBurn, initialTotalShares, approvedTokens),
            "Moloch::ragequit - withdrawal of tokens from guildBank failed"
        );
    }

    function proxyWithdrawTokens(address tokenAddress, address receiver, uint256 amount) public onlyAuthorizedProxy {
        require(guildBank.withdrawToken(tokenAddress, receiver, amount));
    }

    // TODO
    // - convert to use id not index
    // - need to convert the whole damn contract...
    // - allow aborting propsosals EITHER in queue but in abortWindow OR not-yet-sponsored proposals
    function abort(uint256 proposalIndex) public {
        require(proposalIndex < proposalQueue.length, "Moloch::abort - proposal does not exist");
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(msg.sender == proposal.applicant, "Moloch::abort - msg.sender must be applicant");
        require(getCurrentPeriod() < proposal.startingPeriod.add(abortWindow), "Moloch::abort - abort window must not have passed");
        require(!proposal.aborted, "Moloch::abort - proposal must not have already been aborted");

        uint256 tokensToAbort = proposal.tokenTribute;
        proposal.tokenTribute = 0;
        proposal.aborted = true;

        for (var i=0; i < proposal.applicants.length; i++) {
            // return all tokens to the applicant
            require(
                approvedToken.transfer(proposal.applicant, tokensToAbort),
                "Moloch::processProposal - failed to return tribute to applicant"
            );
        }

        emit Abort(proposalIndex, msg.sender);
    }

    function updateDelegates(address[] delegateAddresses, uint256[] votes) public onlyMember {
        require(delegateAddresses.length > 0);
        require(delegateAddresses.length == votes.length);

        Member storage member = members[msg.sender];

        // remove votes for existing delegates
        for (var i=0; i < member.delegateKeys; i++) {
            address memory delegateKey = member.delegateKeys[i];
            Delegate storage delegate = delegates[delegateKey];
            delegate.totalVotes = delegate.totalVotes.sub(member.delegatedVotes[delegateKey]);
            LinkedMember linkedMember = delegate.linkedMembers[msg.sender];

        }

        uint256 votesAssigned = 0;

        for (var i=0; i < delegateAddresses.length; i++) {
            if (i > 0) {
                require(delegateAddresses[i] > delegateAddresses[i-1]); // prevent duplicate delegateAddresses by enforcing ascending sort order by address
                Delegate delegate = delegates[delegateAddresses[i]];
            }

            votesAssigned += votes[i];
        }

        require(votesAssigned == member.shares); // must assign 100% of your votes to delegates

    }

    function updateDelegateKey(address newDelegateKey) public onlyMember {
        require(newDelegateKey != address(0), "Moloch::updateDelegateKey - newDelegateKey cannot be 0");

        // skip checks if member is setting the delegate key to their member address
        if (newDelegateKey != msg.sender) {
            require(!members[newDelegateKey].exists, "Moloch::updateDelegateKey - cant overwrite existing members");
            require(!members[memberAddressByDelegateKey[newDelegateKey]].exists, "Moloch::updateDelegateKey - cant overwrite existing delegate keys");
        }

        Member storage member = members[msg.sender];
        memberAddressByDelegateKey[member.delegateKey] = address(0);
        memberAddressByDelegateKey[newDelegateKey] = msg.sender;
        member.delegateKey = newDelegateKey;

        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }

    // https://github.com/gnosis/gnosis-safe-contracts/blob/master/contracts/GnosisSafe.sol
    function executeCall(address to, bytes data) internal returns (bool success) {
        assembly {
            success := call(gas, to, 0, add(data, 0x20), mload(data), 0, 0)
        }
    }

    /***************
    GETTER FUNCTIONS
    ***************/

    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }

    function getCurrentPeriod() public view returns (uint256) {
        return now.sub(summoningTime).div(periodDuration);
    }

    function getProposalQueueLength() public view returns (uint256) {
        return proposalQueue.length;
    }

    // can only ragequit if the latest proposal you voted YES on has been processed
    function canRagequit(uint256 highestIndexYesVote) public view returns (bool) {
        require(highestIndexYesVote < proposalQueue.length, "Moloch::canRagequit - proposal does not exist");
        return proposalQueue[highestIndexYesVote].processed;
    }

    // can only vote if the latest proposal you voted YES on is at least in the grace period
    function canVote(uint256 highestIndexYesVote) public view returns (bool) {
        require(highestIndexYesVote < proposalQueue.length, "Moloch::canVote - proposal does not exist");
        return hasVotingPeriodExpired(proposalQueue[highestIndexYesVote].startingPeriod);
    }

    function hasVotingPeriodExpired(uint256 startingPeriod) public view returns (bool) {
        return getCurrentPeriod() >= startingPeriod.add(votingPeriodLength);
    }

    function getMemberProposalVote(address memberAddress, uint256 proposalIndex) public view returns (Vote) {
        require(members[memberAddress].exists, "Moloch::getMemberProposalVote - member doesn't exist");
        require(proposalIndex < proposalQueue.length, "Moloch::getMemberProposalVote - proposal doesn't exist");
        return proposalQueue[proposalIndex].votesByMember[memberAddress];
    }
}
