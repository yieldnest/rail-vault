// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal ABIs from 0xSplits/splits-swapper and 0xSplits/splits-oracle.
// Deployment addresses: each repository's deployments/1.json.
struct SplitsPair {
    address base;
    address quote;
}

struct SplitsQuote {
    SplitsPair quotePair;
    uint128 baseAmount;
    bytes data;
}

struct SplitsPairFactor {
    SplitsPair quotePair;
    uint32 scaledOfferFactor;
}

struct SplitsCreateOracle {
    address factory;
    bytes data;
}

struct SplitsOracleParams {
    address oracle;
    SplitsCreateOracle createOracleParams;
}

struct SplitsCreateSwapper {
    address owner;
    bool paused;
    address beneficiary;
    address tokenToBeneficiary;
    SplitsOracleParams oracleParams;
    uint32 defaultScaledOfferFactor;
    SplitsPairFactor[] pairScaledOfferFactors;
}

struct SplitsPool {
    address pool;
    uint32 period;
}

struct SplitsPairDetail {
    SplitsPair quotePair;
    SplitsPool pairDetail;
}

struct SplitsOracleInit {
    address owner;
    bool paused;
    uint32 defaultPeriod;
    SplitsPairDetail[] pairDetails;
}

interface ISplitsFactoryMainnet {
    function createSwapper(SplitsCreateSwapper calldata params) external returns (address);
}

interface ISplitsOracleFactoryMainnet {
    function createUniV3Oracle(SplitsOracleInit calldata params) external returns (address);
}

interface ISplitsOracleMainnet {
    function getQuoteAmounts(SplitsQuote[] calldata quotes) external view returns (uint256[] memory);
}

interface ISplitsSwapperMainnet {
    function oracle() external view returns (address);
    function setDefaultScaledOfferFactor(uint32 factor) external;
}

interface ISplitsUniV3Mainnet {
    struct ExactInput {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct Callback {
        ExactInput[] exactInputParams;
        address excessRecipient;
    }

    struct InitFlash {
        SplitsQuote[] quoteParams;
        Callback flashCallbackData;
    }
    function initFlash(address swapper, InitFlash calldata params) external payable;
}

library SplitsMainnet {
    address internal constant FACTORY = 0xa244bbe019cf1BA177EE5A532250be2663Fb55cA;
    address internal constant ORACLE_FACTORY = 0x498f316fEB85a250fdC64B859a130515491EC888;
    address internal constant INTEGRATION = 0x981a6aC55c7D39f50666938CcD0df53D59797e87;
    address internal constant RAIL = 0xe76C6c83af64e4C60245D8C7dE953DF673a7A33D;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant POOL = 0x2837809FD68e4a4104af76bbec5b622b6146B2cb;

    /// @dev Real factory calls on the fork, not local replacement implementations.
    /// 30 minutes and 95% are test parameters, not approved production settings.
    function create(address beneficiary) internal returns (address swapper, address oracle) {
        require(
            FACTORY.code.length > 0 && ORACLE_FACTORY.code.length > 0 && INTEGRATION.code.length > 0,
            "Ethereum mainnet fork required"
        );
        SplitsPairDetail[] memory pairs = new SplitsPairDetail[](1);
        pairs[0] = SplitsPairDetail(SplitsPair(WETH, RAIL), SplitsPool(POOL, 1800));
        oracle = ISplitsOracleFactoryMainnet(ORACLE_FACTORY)
            .createUniV3Oracle(SplitsOracleInit(address(this), false, 1800, pairs));
        swapper = ISplitsFactoryMainnet(FACTORY)
            .createSwapper(
                SplitsCreateSwapper(
                    address(this),
                    false,
                    beneficiary,
                    RAIL,
                    SplitsOracleParams(oracle, SplitsCreateOracle(address(0), "")),
                    950_000,
                    new SplitsPairFactor[](0)
                )
            );
    }
}
