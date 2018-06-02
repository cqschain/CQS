pragma solidity ^0.4.21;

//import "../node_modules/zeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../node_modules/zeppelin-solidity/contracts/math/SafeMath.sol";
import "./CQSToken.sol";

contract CQSSale {

    using SafeMath for uint256;

    // The beneficiary is the future recipient of the funds
    address public beneficiary;

    // The crowdsale has a funding goal, cap, deadline, and minimum contribution
    uint public fundingGoal;
    uint public fundingCap;
    uint public minContribution;
    bool public fundingGoalReached = false;
    bool public fundingCapReached = false;
    bool public saleClosed = false;

    // Time period of sale (UNIX timestamps)
    uint public startTime;
    uint public endTime;
    address public owner;

    // Keeps track of the amount of wei raised
    uint public amountRaised;

    // Refund amount, should it be required
    uint public refundAmount;

    // The ratio of CQS to Ether
    uint public rate = 50000;
    uint public constant LOW_RANGE_RATE = 1;
    uint public constant HIGH_RANGE_RATE = 500000;

    // prevent certain functions from being recursively called
    bool private rentrancy_lock = false;
    bool public paused = false;

    // The token being sold
    CQSToken public tokenReward;

    // A map that tracks the amount of wei contributed by address
    mapping(address => uint256) public balanceOf;

    mapping(address => uint256) public contributions;
    //uint public maxUserContribution = 20 * 1 ether;
    //mapping(address => uint256) public caps;

    // Events
    event GoalReached(address _beneficiary, uint _amountRaised);
    event CapReached(address _beneficiary, uint _amountRaised);
    event FundTransfer(address _backer, uint _amount, bool _isContribution);
    event Pause();
    event Unpause();

    // Modifiers
    modifier beforeDeadline()   {require (currentTime() < endTime); _;}
    modifier afterDeadline()    {require (currentTime() >= endTime); _;}
    modifier afterStartTime()    {require (currentTime() >= startTime); _;}

    modifier saleNotClosed()    {require (!saleClosed); _;}

    modifier nonReentrant() {
        require(!rentrancy_lock);
        rentrancy_lock = true;
        _;
        rentrancy_lock = false;
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    
    /**
    * @dev Modifier to make a function callable only when the contract is not paused.
    */
    modifier whenNotPaused() {
        require(!paused);
        _;
    }

    /**
    * @dev Modifier to make a function callable only when the contract is paused.
    */
    modifier whenPaused() {
        require(paused);
        _;
    }

    /**
    * @dev called by the owner to pause, triggers stopped state
    */
    function pause() onlyOwner whenNotPaused public {
        paused = true;
        tokenReward.stopICO();
        emit Pause();
    }

    /**
    * @dev called by the owner to unpause, returns to normal state
    */
    function unpause() onlyOwner whenPaused public {
        paused = false;
        tokenReward.startICO();
        emit Unpause();
    }


    constructor(
        address ifSuccessfulSendTo,
        uint fundingGoalInEthers,
        uint fundingCapInEthers,
        uint minimumContributionInWei,
        uint start,
        uint end,
        uint rateCQSToEther,
        address addressOfTokenUsedAsReward
    ) public {
        require(ifSuccessfulSendTo != address(0) && ifSuccessfulSendTo != address(this));
        require(addressOfTokenUsedAsReward != address(0) && addressOfTokenUsedAsReward != address(this));
        require(fundingGoalInEthers <= fundingCapInEthers);
        require(end > 0);
        beneficiary = ifSuccessfulSendTo;
        fundingGoal = fundingGoalInEthers * 1 ether;
        fundingCap = fundingCapInEthers * 1 ether;
        minContribution = minimumContributionInWei;
        startTime = start;
        endTime = end; // TODO double check
        rate = rateCQSToEther;
        tokenReward = CQSToken(addressOfTokenUsedAsReward);
        owner = msg.sender;
    }


    function () external payable whenNotPaused beforeDeadline afterStartTime saleNotClosed nonReentrant {
        require(msg.value >= minContribution);
        //require(contributions[msg.sender].add(msg.value) <= maxUserContribution);

        // Update the sender's balance of wei contributed and the amount raised
        uint amount = msg.value;
        uint currentBalance = balanceOf[msg.sender];
        balanceOf[msg.sender] = currentBalance.add(amount);
        amountRaised = amountRaised.add(amount);

        // Compute the number of tokens to be rewarded to the sender
        // Note: it's important for this calculation that both wei
        // and CQS have the same number of decimal places (18)
        uint numTokens = amount.mul(rate);

        // Transfer the tokens from the crowdsale supply to the sender
        if (tokenReward.transferFrom(tokenReward.owner(), msg.sender, numTokens)) {
            emit FundTransfer(msg.sender, amount, true);
            contributions[msg.sender] = contributions[msg.sender].add(amount);
            // Following code is to automatically transfer ETH to beneficiary
            //uint balanceToSend = this.balance;
            //beneficiary.transfer(balanceToSend);
            //FundTransfer(beneficiary, balanceToSend, false);
            checkFundingGoal();
            checkFundingCap();
        }
        else {
            revert();
        }
    }

    function terminate() external onlyOwner {
        saleClosed = true;
        tokenReward.stopICO();
    }

    function setRate(uint _rate) external onlyOwner {
        require(_rate >= LOW_RANGE_RATE && _rate <= HIGH_RANGE_RATE);
        rate = _rate;
    }

    function ownerAllocateTokens(address _to, uint amountWei, uint amountMiniCQS) external
            onlyOwner nonReentrant
    {
        if (!tokenReward.transferFrom(tokenReward.owner(), _to, amountMiniCQS)) {
            revert();
        }
        balanceOf[_to] = balanceOf[_to].add(amountWei);
        amountRaised = amountRaised.add(amountWei);
        emit FundTransfer(_to, amountWei, true);
        checkFundingGoal();
        checkFundingCap();
    }

    function ownerSafeWithdrawal() external onlyOwner nonReentrant {
        require(fundingGoalReached);
        uint balanceToSend = address(this).balance;
        beneficiary.transfer(balanceToSend);
        emit FundTransfer(beneficiary, balanceToSend, false);
    }

    function ownerUnlockFund() external afterDeadline onlyOwner {
        fundingGoalReached = false;
    }

    function safeWithdrawal() external afterDeadline nonReentrant {
        if (!fundingGoalReached) {
            uint amount = balanceOf[msg.sender];
            balanceOf[msg.sender] = 0;
            if (amount > 0) {
                msg.sender.transfer(amount);
                emit FundTransfer(msg.sender, amount, false);
                refundAmount = refundAmount.add(amount);
            }
        }
    }

    function checkFundingGoal() internal {
        if (!fundingGoalReached) {
            if (amountRaised >= fundingGoal) {
                fundingGoalReached = true;
                emit GoalReached(beneficiary, amountRaised);
            }
        }
    }

    function checkFundingCap() internal {
        if (!fundingCapReached) {
            if (amountRaised >= fundingCap) {
                fundingCapReached = true;
                saleClosed = true;
                emit CapReached(beneficiary, amountRaised);
            }
        }
    }

    function currentTime() public view returns (uint _currentTime) {
        return block.timestamp;
    }

    function convertToMiniCQS(uint amount) internal view returns (uint) {
        return amount * (10 ** uint(tokenReward.decimals()));
    }

    function changeStartTime(uint256 _startTime) external onlyOwner {startTime = _startTime;}
    function changeEndTime(uint256 _endTime) external onlyOwner {endTime = _endTime;}

}