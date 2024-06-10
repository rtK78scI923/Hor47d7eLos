// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PCEToken } from "./PCEToken.sol";
import { Utils } from "./lib/Utils.sol";
import { EIP3009 } from "./lib/EIP3009.sol";
import { TokenSetting } from "./lib/TokenSetting.sol";
import { IERC20Internal } from "./lib/IERC20Internal.sol";
import { ExchangeAllowMethod } from "./lib/Enum.sol";

import { console } from "hardhat/console.sol";

contract PCECommunityToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    EIP3009,
    TokenSetting
{
    using SafeMath for uint256;
    uint256 public constant INITIAL_FACTOR = 10 ** 18;
    uint16 public constant BP_BASE = 10000;
    uint16 public constant MAX_CHARACTER_LENGTH = 10;

    address public pceAddress;
    uint256 public initialFactor;
    uint256 public epochTime;
    uint256 public lastModifiedFactor;

    struct AccountInfo {
        uint256 midnightBalance;
        uint256 firstTransactionTime;
        uint256 lastModifiedMidnightBalanceTime;
        uint256 mintArigatoCreationToday;
    }
    mapping(address user => AccountInfo accountInfo) private _accountInfos;

    event PCETransfer(address indexed from, address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MintArigatoCreation(address indexed to, uint256 displayAmount, uint256 rawAmount);
    event MetaTransactionFeeCollected(address indexed from, address indexed to, uint256 displayFee, uint256 rawFee);

    function initialize(string memory name, string memory symbol, uint256 _initialFactor) public initializer {
        __ERC20_init(name, symbol);
        __Ownable_init();
        pceAddress = _msgSender();
        epochTime = block.timestamp;
        lastDecreaseTime = block.timestamp;
        initialFactor = _initialFactor;
        lastModifiedFactor = _initialFactor;
    }

    function getCurrentFactor() public view returns (uint256) {
        if (lastModifiedFactor == 0) {
            return 0;
        }
        if (decreaseIntervalDays == 0) {
            return lastModifiedFactor;
        }
        if (intervalDaysOf(lastDecreaseTime, block.timestamp, decreaseIntervalDays)) {
            return lastModifiedFactor.mul(afterDecreaseBp).div(BP_BASE);
        } else {
            return lastModifiedFactor;
        }
    }

    function updateFactorIfNeeded() public {
        if (lastDecreaseTime == block.timestamp) {
            return;
        }

        PCEToken pceToken = PCEToken(pceAddress);
        pceToken.updateFactorIfNeeded();

        uint256 currentFactor = getCurrentFactor();
        if (currentFactor != lastModifiedFactor) {
            lastModifiedFactor = currentFactor;
            lastDecreaseTime = block.timestamp;
        }
    }

    function rawBalanceToDisplayBalance(uint256 rawBalance) public view returns (uint256) {
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor < 1) {
            currentFactor = 1;
        }
        return rawBalance.div(currentFactor);
    }

    function displayBalanceToRawBalance(uint256 displayBalance) public view returns (uint256) {
        uint256 currentFactor = getCurrentFactor();
        if (currentFactor < 1) {
            currentFactor = 1;
        }
        return displayBalance.mul(currentFactor);
    }

    function totalSupply() public view override returns (uint256) {
        return rawBalanceToDisplayBalance(super.totalSupply());
    }

    function balanceOf(address account) public view override returns (uint256) {
        return rawBalanceToDisplayBalance(super.balanceOf(account));
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        if (midnightTotalSupplyModifiedTime == 0) {
            midnightTotalSupply = amount;
            midnightTotalSupplyModifiedTime = block.timestamp;
        } else if (intervalDaysOf(midnightTotalSupplyModifiedTime, block.timestamp, 1)) {
            midnightTotalSupply = super.totalSupply();
            midnightTotalSupplyModifiedTime = block.timestamp;
            // Reset arigatoCreateionMintToday, but set it to 1 instead of 0 to reduce gas consumption
            mintArigatoCreationToday = 1;
            mintArigatoCreationTodayForGuest = 1;
        }
        if (from != address(0)) {
            _beforeTokenTransferAtAddress(from);
        }
        if (to != address(0)) {
            _beforeTokenTransferAtAddress(to);
        }
    }

    function _beforeTokenTransferAtAddress(address account) internal {
        if (_accountInfos[account].firstTransactionTime == 0) {
            _accountInfos[account].firstTransactionTime = block.timestamp;
            _accountInfos[account].lastModifiedMidnightBalanceTime = block.timestamp;
            _accountInfos[account].midnightBalance = super.balanceOf(account);
        } else if (intervalDaysOf(_accountInfos[account].lastModifiedMidnightBalanceTime, block.timestamp, 1)) {
            _accountInfos[account].lastModifiedMidnightBalanceTime = block.timestamp;
            _accountInfos[account].midnightBalance = super.balanceOf(account);
            // Reset arigatoCreateionMintToday, but set it to 1 instead of 0 to reduce gas consumption
            _accountInfos[account].mintArigatoCreationToday = 1;
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
        emit PCETransfer(from, to, rawBalanceToDisplayBalance(amount), amount);
    }

    function _mintArigatoCreation(
        address sender,
        uint256 rawAmount,
        uint256 rawBalance,
        uint256 messageCharacters
    ) internal {
        // ** Global mint limit
        uint256 maxArigatoCreationMintToday = midnightTotalSupply.mul(maxIncreaseOfTotalSupplyBp).div(BP_BASE);
        console.log("maxtArigatoCreationToday: %s", maxArigatoCreationMintToday);
        console.log("mintArigatoCreationToday: %s", mintArigatoCreationToday);
        if (maxArigatoCreationMintToday <= 0 || maxArigatoCreationMintToday <= mintArigatoCreationToday) {
            console.log("return 167");
            return;
        }
        uint256 remainingArigatoCreationMintToday = maxArigatoCreationMintToday.sub(mintArigatoCreationToday);
        uint256 remainingArigatoCreationMintTodayForGuest;

        AccountInfo memory accountInfo = _accountInfos[sender];

        bool isGuest = accountInfo.firstTransactionTime == accountInfo.lastModifiedMidnightBalanceTime;
        if (isGuest) {
            uint256 maxArigatoCreationMintTodayForGuest = maxArigatoCreationMintToday.div(10);
            if (
                maxArigatoCreationMintTodayForGuest <= 0 ||
                maxArigatoCreationMintTodayForGuest <= mintArigatoCreationTodayForGuest
            ) {
                console.log("return 182");
                return;
            }
            remainingArigatoCreationMintTodayForGuest = maxArigatoCreationMintTodayForGuest.sub(
                mintArigatoCreationTodayForGuest
            );
        }

        // ** Calculation of mint amount
        // increaseRate = (maxIncreaseRate - changeRate * abs(maxUsageRate - usageRate)) * valueOfMessageCharacter
        uint256 usageBp = rawAmount.mul(BP_BASE).div(rawBalance);
        uint256 absUsageBp = usageBp > maxUsageBp ? usageBp.sub(maxUsageBp) : uint256(maxUsageBp).sub(usageBp);
        uint256 changeMulBp = uint256(changeBp).mul(absUsageBp).div(BP_BASE);
        if (changeMulBp >= maxIncreaseBp) {
            console.log("changeMulBp >= maxIncreaseBp %s >= %s", changeMulBp, maxIncreaseBp);
            return;
        }
        uint256 messageLength = messageCharacters > 0 ? messageCharacters : 1;
        uint256 messageBp = messageLength > MAX_CHARACTER_LENGTH
            ? BP_BASE
            : messageLength.mul(BP_BASE).div(MAX_CHARACTER_LENGTH);
        console.log("rawAmount: %s, rawBalance: %s", rawAmount, rawBalance);
        console.log("usageBp: %s, absUsageBp: %s", usageBp, absUsageBp);
        console.log("messageLength: %s, messageBp: %s", messageLength, messageBp);
        console.log("maxIncreaseBp: %s, changeBp: %s", maxIncreaseBp, uint256(changeBp));
        console.log("changebpmul %s", changeMulBp);

        uint256 increaseBp = uint256(maxIncreaseBp).sub(changeMulBp).mul(messageBp).div(BP_BASE);
        console.log("increaseBp: %s", increaseBp);

        uint256 mintAmount = rawAmount.mul(increaseBp).div(BP_BASE);
        console.log("mintAmount: %s", mintAmount);
        if (mintAmount > remainingArigatoCreationMintToday) {
            console.log("mintAmount > remainingArigatoCreationMintToday %s", remainingArigatoCreationMintToday);
            mintAmount = remainingArigatoCreationMintToday;
        }

        // ** Sender mint limit
        if (!isGuest) {
            console.log("accountInfo.midnightBalance: %s", accountInfo.midnightBalance);
            console.log("midnightTotalSupply: %s", midnightTotalSupply);
            uint256 maxArigatoCreationMintTodayForSender = maxArigatoCreationMintToday
                .mul(accountInfo.midnightBalance)
                .div(midnightTotalSupply);
            if (maxArigatoCreationMintTodayForSender <= 0) {
                console.log(
                    "return maxArigatoCreationMintTodayForSender <= 0 %s",
                    maxArigatoCreationMintTodayForSender
                );
                return;
            }
            if (mintAmount > maxArigatoCreationMintTodayForSender) {
                mintAmount = maxArigatoCreationMintTodayForSender;
            }
        } else {
            // Guest can mint only 1% of maxArigatoCreationMintToday
            if (mintAmount > remainingArigatoCreationMintTodayForGuest) {
                console.log(
                    "mintAmount > remainingArigatoCreationMintTodayForGuest %s",
                    remainingArigatoCreationMintTodayForGuest
                );
                mintAmount = remainingArigatoCreationMintTodayForGuest;
            }
            uint256 maxArigatoCreationMintTodayForGuestSender = maxArigatoCreationMintToday.div(100);
            if (maxArigatoCreationMintTodayForGuestSender <= 0) {
                console.log(
                    "return maxArigatoCreationMintTodayForGuestSender <= 0 %s",
                    maxArigatoCreationMintTodayForGuestSender
                );
                return;
            }
            if (mintAmount > maxArigatoCreationMintTodayForGuestSender) {
                console.log(
                    "mintAmount > maxArigatoCreationMintTodayForGuestSender %s",
                    maxArigatoCreationMintTodayForGuestSender
                );
                mintAmount = maxArigatoCreationMintTodayForGuestSender;
            }
        }

        // ** Execute mint
        _mint(sender, mintAmount);
        unchecked {
            accountInfo.mintArigatoCreationToday += mintAmount;
            mintArigatoCreationToday += mintAmount;
            if (isGuest) {
                mintArigatoCreationTodayForGuest += mintAmount;
            }
        }
        emit MintArigatoCreation(sender, rawBalanceToDisplayBalance(mintAmount), mintAmount);
        console.log("complete mintAmount: %s", mintAmount);
    }

    function transfer(address receiver, uint256 displayAmount) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(_msgSender());
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        // console.log("rawBalance", rawBalance);
        // console.log("rawAmount: %s, displayAmount: %s", rawAmount, displayAmount);
        bool ret = super.transfer(receiver, rawAmount);

        _mintArigatoCreation(_msgSender(), rawAmount, rawBalance, 1);

        return ret;
    }

    function transferFrom(address sender, address receiver, uint256 displayBalance) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(sender);
        uint256 rawAmount = displayBalanceToRawBalance(displayBalance);
        bool ret = super.transferFrom(sender, receiver, rawAmount);

        _mintArigatoCreation(sender, rawAmount, rawBalance, 1);

        return ret;
    }

    function approve(address spender, uint256 displayBalance) public override returns (bool) {
        updateFactorIfNeeded();
        uint256 rawBalance = displayBalanceToRawBalance(displayBalance);
        return super.approve(spender, rawBalance);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return rawBalanceToDisplayBalance(super.allowance(owner, spender));
    }

    function mint(address to, uint256 displayBalance) external {
        updateFactorIfNeeded();
        _mint(to, displayBalanceToRawBalance(displayBalance));
    }

    function burn(uint256 displayBalance) public override {
        updateFactorIfNeeded();
        super.burn(displayBalanceToRawBalance(displayBalance));
    }

    function burnFrom(address account, uint256 displayBalance) public override {
        updateFactorIfNeeded();
        super.burnFrom(account, displayBalanceToRawBalance(displayBalance));
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 rawAmount
    ) internal override(IERC20Internal, ERC20Upgradeable) {
        super._transfer(sender, recipient, rawAmount);
    }

    function intervalDaysOf(uint start, uint end, uint intervalDays) public pure returns (bool) {
        if (start >= end) {
            return false;
        }
        uint startDay = start / 1 days;
        uint endDay = end / 1 days;
        if (startDay == endDay) {
            return false;
        }
        return (endDay - startDay) >= intervalDays;
    }

    function _isAllowExchange(bool isIncome, address tokenAddress) private view returns (bool) {
        ExchangeAllowMethod allowMethod = isIncome ? incomeExchangeAllowMethod : outgoExchangeAllowMethod;
        address[] memory targetTokens = isIncome ? incomeTargetTokens : outgoTargetTokens;
        if (allowMethod == ExchangeAllowMethod.None) {
            return false;
        } else if (allowMethod == ExchangeAllowMethod.All) {
            return true;
        } else if (allowMethod == ExchangeAllowMethod.Include) {
            for (uint256 i = 0; i < targetTokens.length; ) {
                if (targetTokens[i] == tokenAddress) {
                    return true;
                }
                unchecked {
                    i++;
                }
            }
            return false;
        } else if (allowMethod == ExchangeAllowMethod.Exclude) {
            for (uint256 i = 0; i < targetTokens.length; ) {
                if (targetTokens[i] == tokenAddress) {
                    return false;
                }
                unchecked {
                    i++;
                }
            }
            return true;
        } else {
            revert("Invalid exchangeAllowMethod");
        }
    }

    function isAllowOutgoExchange(address tokenAddress) public view returns (bool) {
        return _isAllowExchange(false, tokenAddress);
    }

    function isAllowIncomeExchange(address tokenAddress) public view returns (bool) {
        return _isAllowExchange(true, tokenAddress);
    }

    /*
        @dev Swap tokens
        @param toTokenAddress Address of token to swap
        @param amountToSwap Amount of token to swap
    */

    function swapTokens(address toTokenAddress, uint256 amountToSwap) public {
        address sender = _msgSender();
        updateFactorIfNeeded();
        PCEToken pceToken = PCEToken(pceAddress);
        pceToken.updateFactorIfNeeded();

        Utils.LocalToken memory fromToken = pceToken.getLocalToken(address(this));
        require(fromToken.isExists, "From token not found");

        Utils.LocalToken memory toToken = pceToken.getLocalToken(toTokenAddress);
        require(toToken.isExists, "Target token not found");

        PCECommunityToken to = PCECommunityToken(toTokenAddress);
        to.updateFactorIfNeeded();

        require(balanceOf(sender) >= amountToSwap, "Insufficient balance");
        require(isAllowOutgoExchange(toTokenAddress), "Outgo exchange not allowed");
        require(to.isAllowIncomeExchange(address(this)), "Income exchange not allowed");

        uint256 targetTokenAmount = amountToSwap
            .mul(10 ** 18)
            .div(fromToken.exchangeRate)
            .mul(pceToken.getCurrentFactor())
            .div(getCurrentFactor());
        targetTokenAmount = targetTokenAmount
            .mul(toToken.exchangeRate)
            .div(INITIAL_FACTOR)
            .mul(to.getCurrentFactor())
            .div(pceToken.getCurrentFactor());
        require(targetTokenAmount > 0, "Invalid amount to swap");

        super._burn(sender, displayBalanceToRawBalance(amountToSwap));
        to.mint(sender, targetTokenAmount);
    }

    /*
        @notice Returns the fee in this token for the meta transaction in the current block.
    */
    function getMetaTransactionFee() public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);
        uint256 pceTokenFee = pceToken.getMetaTransactionFee();
        uint256 rate = pceToken.getSwapRate(address(this));
        return pceTokenFee.mul(rate) >> 96;
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 displayAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        updateFactorIfNeeded();
        uint256 rawBalance = super.balanceOf(from);
        uint256 rawAmount = displayBalanceToRawBalance(displayAmount);
        uint256 displayFee = getMetaTransactionFee();
        uint256 rawFee = displayBalanceToRawBalance(displayFee);
        _transferWithAuthorization(from, to, displayAmount, validAfter, validBefore, nonce, v, r, s, rawAmount);

        super._transfer(from, _msgSender(), rawFee);

        emit MetaTransactionFeeCollected(from, _msgSender(), displayFee, rawFee);

        _mintArigatoCreation(from, rawAmount, rawBalance, 1);
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today
        The balance is 0.01 times the total supply at UTC 0
    */
    function getTodaySwapableToPCEBalance() public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);

        return rawBalanceToDisplayBalance(midnightTotalSupply.mul(pceToken.swapableToPCERate()).div(BP_BASE));
    }

    /*
        @notice Returns the total balance that can be swapped to PCE today for the individual
        The balance is 0.01 times the balance of the individual at UTC 0
    */
    function getTodaySwapableToPCEBalanceForIndividual(address checkAddress) public view returns (uint256) {
        PCEToken pceToken = PCEToken(pceAddress);

        AccountInfo memory accountInfo = _accountInfos[checkAddress];

        return
            rawBalanceToDisplayBalance(
                accountInfo.midnightBalance.mul(pceToken.swapableToPCEIndividualRate()).div(BP_BASE)
            );
    }
}
