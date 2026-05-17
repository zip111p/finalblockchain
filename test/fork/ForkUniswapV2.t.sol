// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendingPool} from "../../src/lending/LendingPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockChainlinkAdapter} from "../mocks/MockChainlinkAdapter.sol";

/// @dev Minimal Uniswap V2 Router interface — only what the tests need
interface IUniswapV2Router02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/// @notice Fork tests: interact with the real Uniswap V2 Router on mainnet,
///         then feed acquired USDC into our RWA LendingPool.
/// Run with: forge test --fork-url $MAINNET_RPC_URL --match-contract ForkUniswapV2Test
contract ForkUniswapV2Test is Test {
    using SafeERC20 for IERC20;

    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH             = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC             = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 constant ETH_IN = 1 ether;

    IUniswapV2Router02 public router;
    LendingPool         public pool;
    MockERC20           public rwaToken;
    MockChainlinkAdapter public oracle;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(mainnetFork);

        router   = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        rwaToken = new MockERC20("RWA Token", "RWAT", 18);
        oracle   = new MockChainlinkAdapter(100e18, 1_000_000e18); // $100 per RWAT
        pool     = new LendingPool(IERC20(address(rwaToken)), IERC20(USDC), oracle, owner);

        vm.deal(alice, 10 ether);
        vm.deal(owner, 10 ether);
    }

    /// @notice Uniswap V2 quote for 1 ETH → USDC must be in a reasonable range
    function test_fork_uniswap_getAmountsOut_isReasonable() public view {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint256[] memory amounts = router.getAmountsOut(ETH_IN, path);
        uint256 usdcOut = amounts[1]; // USDC has 6 decimals

        console2.log("Uniswap V2 quote: 1 ETH =>", usdcOut, "USDC (6 dec)");

        // ETH price must be between $100 and $100,000
        assertGt(usdcOut, 100e6,     "ETH price too low");
        assertLt(usdcOut, 100_000e6, "ETH price too high");
    }

    /// @notice Swap ETH for real USDC on-chain, then use it to fund our LendingPool
    function test_fork_uniswap_swapEthForUsdc_thenFundPool() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint256[] memory quote  = router.getAmountsOut(ETH_IN, path);
        uint256 minUsdc = (quote[1] * 95) / 100; // 5% slippage tolerance

        vm.prank(alice);
        uint256[] memory received = router.swapExactETHForTokens{value: ETH_IN}(
            minUsdc,
            path,
            alice,
            block.timestamp + 300
        );

        uint256 usdcReceived = received[1];
        assertGt(usdcReceived, 0, "Should receive USDC after swap");
        console2.log("USDC received:", usdcReceived);

        // Provide the swapped USDC as liquidity to our RWA LendingPool
        vm.startPrank(alice);
        IERC20(USDC).approve(address(pool), usdcReceived);
        pool.provideLiquidity(usdcReceived);
        vm.stopPrank();

        assertEq(pool.availableLiquidity(), usdcReceived, "Pool liquidity must match deposited USDC");
        console2.log("Pool liquidity after fund:", pool.availableLiquidity());
    }

    /// @notice Full flow: swap ETH → USDC, fund pool, deposit RWA collateral, borrow USDC
    function test_fork_uniswap_fullFlow_swapFundBorrow() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // 1. Swap 2 ETH for USDC to fund the pool
        uint256[] memory quote = router.getAmountsOut(2 ether, path);
        uint256 minUsdc = (quote[1] * 95) / 100;

        vm.startPrank(owner);
        uint256[] memory received = router.swapExactETHForTokens{value: 2 ether}(
            minUsdc,
            path,
            owner,
            block.timestamp + 300
        );
        IERC20(USDC).approve(address(pool), received[1]);
        pool.provideLiquidity(received[1]);
        vm.stopPrank();

        uint256 poolLiquidity = pool.availableLiquidity();
        assertGt(poolLiquidity, 0, "Pool must have USDC liquidity");

        // 2. Alice deposits RWA collateral
        uint256 collateralAmt = 1000e18; // 1000 RWAT @ $100 = $100,000 collateral
        rwaToken.mint(alice, collateralAmt);
        vm.startPrank(alice);
        IERC20(address(rwaToken)).approve(address(pool), collateralAmt);
        pool.depositCollateral(collateralAmt);

        // 3. Alice borrows USDC at 60% LTV
        // collateralValue = 1000 * $100 = $100,000; 60% LTV = $60,000 = 60,000e6 USDC
        uint256 borrowAmt = 60_000e6;
        if (borrowAmt > poolLiquidity) borrowAmt = poolLiquidity / 2;

        pool.borrow(borrowAmt);
        vm.stopPrank();

        assertGt(pool.currentDebt(alice), 0, "Alice must have debt after borrow");
        assertGt(pool.healthFactor(alice), 1e18, "Health factor must be above 1.0");
        console2.log("Alice debt (USDC):", pool.currentDebt(alice));
        console2.log("Alice health factor:", pool.healthFactor(alice));
    }
}
