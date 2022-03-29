// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "../interfaces/compound/CErc20I.sol";
import "../interfaces/compound/ComptrollerI.sol";
import {IUniswapV2Router} from "../interfaces/uniswap/IUniswapV2Router.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address private constant addr_anYFI = 0xde2af899040536884e062D3a334F2dD36F34b4a4;
    address private constant addr_comp_of_inverse = 0x4dCf7407AE5C07f8681e1659f626E114A7667339;
    address private constant addr_INV = 0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68;
    address private constant addr_xINV = 0x1637e4e9941D55703a7A5E7807d6aDA3f7DCD61B;
    address private constant addr_weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    CErc20I anYFI = CErc20I(addr_anYFI);
    IERC20 INV = IERC20(addr_INV); 
    CErc20I xINV = CErc20I(addr_xINV);
    IERC20 weth = IERC20(addr_weth);
    ComptrollerI comp_of_inverse = ComptrollerI(addr_comp_of_inverse);

    // SWAP routers
    IUniswapV2Router private constant SUSHI_V2_ROUTER =
        IUniswapV2Router(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    
    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        want.approve(addr_anYFI, uint256(-1));
        INV.approve(addr_xINV, uint256(-1));
        INV.approve(address(SUSHI_V2_ROUTER), uint256(-1));
        want.approve(address(SUSHI_V2_ROUTER), uint256(-1));

    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyInverseYFI";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        uint inv_in_xInv_values_as_YFI = quoteINV2YFIOnSushi(xINV.balanceOf(address(this)).mul(xINV.exchangeRateStored()).div(10**18));
        
        //inv_value = inv_amount * price
        return want.balanceOf(address(this)).add(anYFI.balanceOf(address(this)).mul(anYFI.exchangeRateStored()).div(10**18)).add(inv_in_xInv_values_as_YFI);
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
        
        
        
        if(_debtOutstanding > 0){
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
            require(_loss == 0, "redeem loss");
        }

        StrategyParams memory params = vault.strategies(address(this));
        // I cannot find the forked comptroller address of inverse finance. 
        // Where to claim comp?
        // Comptroller.claimComp(address(this));
        // @FP told me a way to find it. use etherscan to check anToken relative contracts.
        // https://etherscan.io/address/0xde2af899040536884e062D3a334F2dD36F34b4a4#readContract

        uint256 totalAssets = estimatedTotalAssets();
        if(params.totalDebt <= totalAssets){
             _profit = totalAssets.sub(params.totalDebt);           
        }
        else{
            _loss = params.totalDebt.sub(totalAssets);
        }

        
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
        
        
        if(want.balanceOf(address(this)) > _debtOutstanding){
            anYFI.mint(want.balanceOf(address(this)).sub(_debtOutstanding));
            comp_of_inverse.claimComp(address(this));
            uint256 amount_of_inv = INV.balanceOf(address(this));
            if(amount_of_inv > 0){
                require(xINV.mint(amount_of_inv) == 0, "xINV mint error");
            }
        }

        
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        _amountNeeded = _amountNeeded.sub(want.balanceOf(address(this)));

        if(_amountNeeded < anYFI.balanceOfUnderlying(address(this))){
            _liquidatedAmount = _amountNeeded;
            require(anYFI.redeemUnderlying(_amountNeeded) == 0, "anYFI redeem some, operation error code");

        }
        else{
            _liquidatedAmount = anYFI.balanceOfUnderlying(address(this));
            _loss = _amountNeeded.sub(_liquidatedAmount);
            require(anYFI.redeem(anYFI.balanceOf(address(this))) == 0, "cDai redeem all, operation error code");
            
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        anYFI.redeem(anYFI.balanceOf(address(this)));
        xINV.redeem(xINV.balanceOf(address(this)));
        comp_of_inverse.claimComp(address(this));
        if(INV.balanceOf(address(this)) > 0)
            _sellINVForWant(INV.balanceOf(address(this)), 0);
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        anYFI.transfer(_newStrategy, anYFI.balanceOf(address(this)));
        INV.transfer(_newStrategy, anYFI.balanceOf(address(this)));

    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    function getTokenOutPathV2(address _token_in, address _token_out)
        internal
        pure
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == addr_weth || _token_out == addr_weth;
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;

        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = addr_weth;
            _path[2] = _token_out;
        }
    }

    function quoteINV2YFIOnSushi(uint256 INV_amount) internal view returns(uint256 YFI_amount){

        if(INV_amount > 0){
            uint256[] memory amounts = SUSHI_V2_ROUTER.getAmountsOut(
                    INV_amount,
                    getTokenOutPathV2(addr_INV, address(want))
                );
            YFI_amount = amounts[amounts.length - 1];
        }
    }
    
    function _sellINVForWant(uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) {
            return;
        }
        SUSHI_V2_ROUTER.swapExactTokensForTokens(
                amountIn,
                minOut,
                getTokenOutPathV2(addr_INV, address(want)),
                address(this),
                now
            );
    }


}
